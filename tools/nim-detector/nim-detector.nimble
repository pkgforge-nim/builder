import os, json, strutils, sequtils, times, math
import std/parsecfg

type
  OutputFormat = enum
    ofJson = "json"
    ofTable = "table"
    ofSummary = "summary"

  PackageType = enum
    ptLibrary = "library"
    ptCLI = "cli"
    ptBoth = "both"
    ptUnknown = "unknown"
  
  PackageInfo = object
    name: string
    path: string
    packageType: PackageType
    confidence: float
    evidence: seq[string]
    binaries: seq[string]
    hasMainModule: bool
    nimbleExists: bool
    hasTests: bool
    hasExamples: bool
    nimFiles: seq[string]
    analysisTime: float

  AnalyzerConfig = object
    outputFormat: OutputFormat
    verbose: bool
    recursive: bool
    showHelp: bool
    showVersion: bool
    minConfidence: float
    includeEvidence: bool
    paths: seq[string]

const
  VERSION = "1.1.0"
  CLI_KEYWORDS = ["command", "cli", "tool", "utility", "executable", "binary", "terminal", "console"]
  LIB_KEYWORDS = ["library", "module", "package", "framework", "api", "sdk", "wrapper"]
  CLI_IMPORTS = ["parseopt", "cligen", "docopt", "argparse", "commandeer", "parseutils"]
  SYSTEM_IMPORTS = ["os", "osproc", "terminal", "colors", "strformat", "logging"]

proc parseArgs(): AnalyzerConfig =
  var config = AnalyzerConfig()
  config.outputFormat = ofJson
  config.verbose = false
  config.recursive = false
  config.minConfidence = 0.0
  config.includeEvidence = true
  
  let args = commandLineParams()
  var i = 0
  
  while i < args.len:
    let arg = args[i]
    
    case arg:
    of "-h", "--help":
      config.showHelp = true
      return config
    of "-v", "--version":
      config.showVersion = true
      return config
    of "-f", "--format":
      if i + 1 < args.len:
        i.inc
        case args[i].toLowerAscii()
        of "json": config.outputFormat = ofJson
        of "table": config.outputFormat = ofTable
        of "summary": config.outputFormat = ofSummary
        else:
          stderr.writeLine("Error: Invalid format '" & args[i] & "'. Use: json, table, or summary")
          quit(1)
      else:
        stderr.writeLine("Error: --format requires a value")
        quit(1)
    of "--verbose":
      config.verbose = true
    of "-r", "--recursive":
      config.recursive = true
    of "--min-confidence":
      if i + 1 < args.len:
        i.inc
        try:
          config.minConfidence = parseFloat(args[i])
          if config.minConfidence < 0.0 or config.minConfidence > 1.0:
            raise newException(ValueError, "Confidence must be between 0.0 and 1.0")
        except:
          stderr.writeLine("Error: Invalid confidence value '" & args[i] & "'. Must be between 0.0 and 1.0")
          quit(1)
      else:
        stderr.writeLine("Error: --min-confidence requires a value")
        quit(1)
    of "--no-evidence":
      config.includeEvidence = false
    else:
      if arg.startsWith("-"):
        stderr.writeLine("Error: Unknown option '" & arg & "'")
        quit(1)
      else:
        config.paths.add(arg)
    
    i.inc
  
  return config

proc showHelp() =
  echo """
Nim Package Detector v""" & VERSION & """

USAGE:
    nim-detector [OPTIONS] <path1> [path2] [path3] ...

DESCRIPTION:
    Analyzes Nim packages to determine if they are libraries, CLI tools, or both.
    Provides confidence scores and detailed evidence for classifications.

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -f, --format FORMAT     Output format: json, table, or summary (default: json)
    --verbose               Enable verbose output with timing information
    -r, --recursive         Recursively analyze subdirectories for packages
    --min-confidence FLOAT  Only show results with confidence >= threshold (0.0-1.0)
    --no-evidence           Exclude evidence details from output

FEATURES:
    • Parses .nimble files for binary declarations and metadata
    • Analyzes Nim source files for main modules and export patterns  
    • Examines directory structure and file organization
    • Provides confidence scores with detailed evidence
    • Multiple output formats for different use cases
    • Recursive analysis for discovering nested packages

EXAMPLES:
    nim-detector ./my_package
    nim-detector --format table ./package1 ./package2
    nim-detector --recursive --min-confidence 0.7 ./projects/
    nim-detector --format summary --verbose ./libs/

OUTPUT FORMATS:
    json     - Detailed JSON output with all metadata (default)
    table    - Human-readable table format
    summary  - Concise overview with key statistics
"""

proc parseNimbleFile(path: string): tuple[binaries: seq[string], evidence: seq[string]] =
  var binaries: seq[string] = @[]
  var evidence: seq[string] = @[]
  
  if not fileExists(path):
    return (binaries, evidence)
  
  try:
    let config = loadConfig(path)
    
    try:
      let binStr = config.getSectionValue("", "bin")
      if binStr.len > 0:
        evidence.add("Found bin declaration in .nimble file")
        if binStr.contains("@["):
          var inQuotes = false
          var current = ""
          for ch in binStr:
            if ch == '"':
              if inQuotes:
                if current.len > 0:
                  binaries.add(current)
                  current = ""
                inQuotes = false
              else:
                inQuotes = true
            elif inQuotes:
              current.add(ch)
        elif binStr.contains("\""):
          let start = binStr.find('"')
          let stop = binStr.find('"', start + 1)
          if start != -1 and stop != -1:
            binaries.add(binStr[start+1..<stop])
        else:
          binaries.add(binStr.strip())
    except:
      discard
    
    let fieldsToCheck = [
      ("binDir", "Found binDir in .nimble file: "),
      ("srcDir", "Found srcDir in .nimble file: "),
      ("installDirs", "Found installDirs in .nimble file"),
      ("installFiles", "Found installFiles in .nimble file")
    ]
    
    for (field, msg) in fieldsToCheck:
      try:
        let value = config.getSectionValue("", field)
        if value.len > 0:
          evidence.add(msg & (if msg.endsWith(": "): value else: ""))
      except:
        discard
    
    try:
      let description = config.getSectionValue("", "description")
      if description.len > 0:
        let descLower = description.toLowerAscii()
        for keyword in CLI_KEYWORDS:
          if keyword in descLower:
            evidence.add("Description suggests CLI tool")
            break
        for keyword in LIB_KEYWORDS:
          if keyword in descLower:
            evidence.add("Description suggests library")
            break
    except:
      discard
      
  except:
    evidence.add("Failed to parse .nimble file")
  
  return (binaries, evidence)

proc analyzeNimFile(filePath: string): tuple[evidence: seq[string], isMain: bool] =
  var evidence: seq[string] = @[]
  var isMain = false
  
  if not fileExists(filePath):
    return (evidence, isMain)
  
  try:
    let content = readFile(filePath)
    let contentLower = content.toLowerAscii()
    let filename = extractFilename(filePath)
    
    if "when ismainmodule:" in contentLower:
      isMain = true
      evidence.add("Found 'when isMainModule:' in " & filename)
    
    if "proc main(" in contentLower or "proc main*(" in contentLower:
      evidence.add("Found main procedure in " & filename)
    
    var foundCliImports: seq[string] = @[]
    for imp in CLI_IMPORTS:
      if ("import " & imp) in contentLower or ("from " & imp) in contentLower:
        foundCliImports.add(imp)
    
    if foundCliImports.len > 0:
      evidence.add("Found CLI imports (" & foundCliImports.join(", ") & ") in " & filename)
    
    var systemImportCount = 0
    var foundSystemImports: seq[string] = @[]
    for imp in SYSTEM_IMPORTS:
      if ("import " & imp) in contentLower or ("from " & imp) in contentLower:
        systemImportCount.inc
        foundSystemImports.add(imp)
    
    if systemImportCount >= 2:
      evidence.add("Multiple system imports (" & foundSystemImports.join(", ") & ") suggest CLI tool")
    
    let lines = content.splitLines()
    var exportedProcs = 0
    var exportedTypes = 0
    var hasExportedTemplates = false
    var hasExportedMacros = false
    
    for line in lines:
      let trimmed = line.strip()
      if trimmed.startsWith("proc ") and "*" in trimmed:
        exportedProcs.inc
      elif trimmed.startsWith("type ") and "*" in trimmed:
        exportedTypes.inc
      elif trimmed.startsWith("template ") and "*" in trimmed:
        hasExportedTemplates = true
      elif trimmed.startsWith("macro ") and "*" in trimmed:
        hasExportedMacros = true
    
    if exportedProcs >= 3:
      evidence.add("Multiple exported procedures (" & $exportedProcs & ") suggest library")
    
    if exportedTypes >= 2:
      evidence.add("Multiple exported types (" & $exportedTypes & ") suggest library")
    
    if hasExportedTemplates:
      evidence.add("Exported templates suggest library")
    
    if hasExportedMacros:
      evidence.add("Exported macros suggest library")
    
  except:
    evidence.add("Failed to analyze " & extractFilename(filePath))
  
  return (evidence, isMain)

proc checkForMainModule(dir: string): tuple[hasMain: bool, evidence: seq[string]] =
  var evidence: seq[string] = @[]
  var hasMain = false
  
  let packageName = extractFilename(dir)
  let mainCandidates = @[
    dir / "src" / packageName & ".nim",
    dir / packageName & ".nim",
    dir / "main.nim",
    dir / "src" / "main.nim",
    dir / "app.nim",
    dir / "src" / "app.nim"
  ]
  
  for candidate in mainCandidates:
    if fileExists(candidate):
      let (fileEvidence, isMainFile) = analyzeNimFile(candidate)
      evidence.add(fileEvidence)
      if isMainFile:
        hasMain = true
  
  if not hasMain:
    let srcDir = dir / "src"
    if dirExists(srcDir):
      for file in walkDirRec(srcDir):
        if file.endsWith(".nim") and not (file in mainCandidates):
          let (fileEvidence, isMainFile) = analyzeNimFile(file)
          evidence.add(fileEvidence)
          if isMainFile:
            hasMain = true
            break
  
  return (hasMain, evidence)

proc findNimFiles(dir: string): seq[string] =
  var nimFiles: seq[string] = @[]
  
  if dirExists(dir):
    for file in walkDirRec(dir):
      if file.endsWith(".nim"):
        nimFiles.add(file)
  
  return nimFiles

proc analyzePackage(packagePath: string): PackageInfo =
  let startTime = cpuTime()
  
  var info = PackageInfo()
  info.name = extractFilename(packagePath)
  info.path = packagePath
  info.evidence = @[]
  info.binaries = @[]
  
  info.nimFiles = findNimFiles(packagePath)
  
  var nimbleFile = ""
  for file in walkDir(packagePath):
    if file.path.endsWith(".nimble"):
      nimbleFile = file.path
      break
  
  info.nimbleExists = nimbleFile.len > 0
  
  if info.nimbleExists:
    let (binaries, nimbleEvidence) = parseNimbleFile(nimbleFile)
    info.binaries = binaries
    info.evidence.add(nimbleEvidence)
  
  let (hasMain, mainEvidence) = checkForMainModule(packagePath)
  info.hasMainModule = hasMain
  info.evidence.add(mainEvidence)
  
  let directories = ["tests", "test", "examples", "example", "docs", "doc", "src", "bin"]
  var dirFlags = newSeq[bool](directories.len)
  
  for i, dirName in directories:
    dirFlags[i] = dirExists(packagePath / dirName)
  
  info.hasTests = dirFlags[0] or dirFlags[1]
  info.hasExamples = dirFlags[2] or dirFlags[3]
  let hasDocDir = dirFlags[4] or dirFlags[5]
  let hasSrcDir = dirFlags[6]
  let hasBinDir = dirFlags[7]
  
  if info.hasTests:
    info.evidence.add("Found tests directory")
  if info.hasExamples:
    info.evidence.add("Found examples directory")
  if hasDocDir:
    info.evidence.add("Found documentation directory")
  if hasBinDir:
    info.evidence.add("Found bin/ directory")
  
  var cliScore = 0.0
  var libScore = 0.0
  
  if info.binaries.len > 0:
    cliScore += 5.0
    info.evidence.add("Strong CLI indicator: " & $info.binaries.len & " explicit binaries declared")
  
  if info.hasMainModule:
    cliScore += 3.5
  
  if hasBinDir:
    cliScore += 2.5
  if hasSrcDir and not hasBinDir and info.nimFiles.len > 3:
    libScore += 1.5
  
  if info.nimbleExists and info.binaries.len == 0 and not info.hasMainModule:
    libScore += 2.5
    info.evidence.add("Nimble file without binaries suggests library")
  
  let evidenceText = info.evidence.join(" ").toLowerAscii()
  
  if "srcdir" in evidenceText:
    libScore += 2.0
  if "installdir" in evidenceText or "installfile" in evidenceText:
    libScore += 2.5
  if "exported procedures" in evidenceText or "exported types" in evidenceText:
    libScore += 3.0
  if "exported templates" in evidenceText or "exported macros" in evidenceText:
    libScore += 2.5
  if "cli import" in evidenceText:
    cliScore += 3.5
  if "cli tool" in evidenceText:
    cliScore += 2.5
  if "system import" in evidenceText:
    cliScore += 2.0
  
  if info.nimFiles.len == 1 and info.hasMainModule:
    cliScore += 1.5
    info.evidence.add("Single file with main module suggests CLI tool")
  elif info.nimFiles.len > 5 and not info.hasMainModule:
    libScore += 1.5
    info.evidence.add("Multiple files without main module suggests library")
  
  if info.hasTests:
    libScore += 0.7
  if info.hasExamples:
    libScore += 1.2
  if hasDocDir:
    libScore += 0.8
  
  let totalScore = cliScore + libScore
  if totalScore < 0.5:
    info.packageType = ptUnknown
    info.confidence = 0.0
    info.evidence.add("Insufficient indicators found")
  elif abs(cliScore - libScore) < 1.5 and cliScore >= 2.0 and libScore >= 2.0:
    info.packageType = ptBoth
    info.confidence = min(cliScore, libScore) / totalScore
  elif cliScore > libScore:
    info.packageType = ptCLI
    info.confidence = min(0.98, cliScore / totalScore)
  else:
    info.packageType = ptLibrary
    info.confidence = min(0.98, libScore / totalScore)
  
  info.analysisTime = cpuTime() - startTime
  return info

proc findPackagesRecursive(rootPath: string): seq[string] =
  var packages: seq[string] = @[]
  
  if not dirExists(rootPath):
    return packages
  
  for file in walkDir(rootPath):
    if file.path.endsWith(".nimble"):
      packages.add(rootPath)
      break
  
  for entry in walkDir(rootPath):
    if entry.kind == pcDir:
      let subPackages = findPackagesRecursive(entry.path)
      packages.add(subPackages)
  
  return packages

proc outputJson(infos: seq[PackageInfo], config: AnalyzerConfig) =
  var jsonOutput = newJObject()
  var packages = newJArray()
  
  for info in infos:
    if info.confidence < config.minConfidence:
      continue
      
    var packageJson = newJObject()
    packageJson["name"] = newJString(info.name)
    packageJson["path"] = newJString(info.path)
    packageJson["type"] = newJString($info.packageType)
    packageJson["confidence"] = newJFloat(round(info.confidence, 3))
    packageJson["has_nimble_file"] = newJBool(info.nimbleExists)
    packageJson["has_main_module"] = newJBool(info.hasMainModule)
    packageJson["has_tests"] = newJBool(info.hasTests)
    packageJson["has_examples"] = newJBool(info.hasExamples)
    packageJson["nim_file_count"] = newJInt(info.nimFiles.len)
    
    if config.verbose:
      packageJson["analysis_time_ms"] = newJFloat(round(info.analysisTime * 1000, 2))
    
    var binariesJson = newJArray()
    for binary in info.binaries:
      binariesJson.add(newJString(binary))
    packageJson["binaries"] = binariesJson
    
    if config.includeEvidence:
      var evidenceJson = newJArray()
      for evidence in info.evidence:
        evidenceJson.add(newJString(evidence))
      packageJson["evidence"] = evidenceJson
    
    packages.add(packageJson)
  
  jsonOutput["packages"] = packages
  jsonOutput["analyzed_count"] = newJInt(infos.len)
  jsonOutput["results_count"] = newJInt(packages.len)
  
  if config.verbose:
    jsonOutput["analyzer_version"] = newJString(VERSION)
    jsonOutput["timestamp"] = newJString($now())
  
  echo jsonOutput.pretty()

proc outputTable(infos: seq[PackageInfo], config: AnalyzerConfig) =
  let filteredInfos = infos.filter(proc(info: PackageInfo): bool = info.confidence >= config.minConfidence)
  
  if filteredInfos.len == 0:
    echo "No packages match the criteria."
    return
  
  var maxNameLen = 4
  var maxTypeLen = 4
  var maxPathLen = 4
  
  for info in filteredInfos:
    maxNameLen = max(maxNameLen, info.name.len)
    maxTypeLen = max(maxTypeLen, ($info.packageType).len)
    maxPathLen = max(maxPathLen, info.path.len)
  
  maxPathLen = min(maxPathLen, 50)
  
  let extraSeparator = if config.verbose: "+" & "-".repeat(12) else: ""
  let separator =
    "+" & "-".repeat(maxNameLen + 2) &
    "+" & "-".repeat(maxTypeLen + 2) &
    "+" & "-".repeat(10) &
    "+" & "-".repeat(maxPathLen + 2) &
    extraSeparator & "+"
  
  echo separator
  let extraHeader = if config.verbose: " | " & "Time (ms)".alignLeft(10) else: ""
  let header = "| " & "Name".alignLeft(maxNameLen) &
               " | " & "Type".alignLeft(maxTypeLen) &
               " | " & "Confidence".alignLeft(8) &
               " | " & "Path".alignLeft(maxPathLen) &
               extraHeader & " |"
  echo header
  echo separator

  for info in filteredInfos:
    let truncatedPath =
      if info.path.len > maxPathLen:
        info.path[0 ..< maxPathLen - 3] & "..."
      else:
        info.path

    let confidenceStr = $(round(info.confidence * 100, 1)) & "%"
    let timeStr =
      if config.verbose:
        $(round(info.analysisTime * 1000, 2))
      else:
        ""

    let timeCol =
      if config.verbose:
        " | " & timeStr.alignLeft(10)
      else:
        ""

    let row = "| " & info.name.alignLeft(maxNameLen) &
              " | " & ($info.packageType).alignLeft(maxTypeLen) &
              " | " & confidenceStr.alignLeft(8) &
              " | " & truncatedPath.alignLeft(maxPathLen) &
              timeCol & " |"

    echo row


  
  echo separator
  echo "Total: " & $filteredInfos.len & " packages"

proc outputSummary(infos: seq[PackageInfo], config: AnalyzerConfig) =
  let filteredInfos = infos.filter(proc(info: PackageInfo): bool = info.confidence >= config.minConfidence)
  
  if filteredInfos.len == 0:
    echo "No packages match the criteria."
    return
  
  var typeCounts = [0, 0, 0, 0]
  var totalConfidence = 0.0
  var highConfidenceCount = 0
  
  for info in filteredInfos:
    case info.packageType:
    of ptLibrary: typeCounts[0].inc
    of ptCLI: typeCounts[1].inc
    of ptBoth: typeCounts[2].inc
    of ptUnknown: typeCounts[3].inc
    
    totalConfidence += info.confidence
    if info.confidence >= 0.8:
      highConfidenceCount.inc
  
  echo "=== Nim Package Analysis Summary ==="
  echo "Total packages analyzed: " & $infos.len
  echo "Packages matching criteria: " & $filteredInfos.len
  echo ""
  echo "Package Types:"
  echo "  Libraries: " & $typeCounts[0] & " (" & $(round(typeCounts[0] / filteredInfos.len * 100, 1)) & "%)"
  echo "  CLI Tools: " & $typeCounts[1] & " (" & $(round(typeCounts[1] / filteredInfos.len * 100, 1)) & "%)"
  echo "  Both: " & $typeCounts[2] & " (" & $(round(typeCounts[2] / filteredInfos.len * 100, 1)) & "%)"
  echo "  Unknown: " & $typeCounts[3] & " (" & $(round(typeCounts[3] / filteredInfos.len * 100, 1)) & "%)"
  echo ""
  echo "Confidence Statistics:"
  echo "  Average confidence: " & $(round(totalConfidence / float(filteredInfos.len) * 100, 1)) & "%"
  echo "  High confidence (≥80%): " & $highConfidenceCount & " packages"

  if config.verbose:
    let totalTime = filteredInfos.foldl(a + b.analysisTime, 0.0)
    echo "  Total analysis time: " & $(round(totalTime * 1000, 2)) & "ms"
    echo "  Average time per package: " & $(round(totalTime / float(filteredInfos.len) * 1000, 2)) & "ms"

proc main() =
  let config = parseArgs()
  
  if config.showHelp:
    showHelp()
    return
  
  if config.showVersion:
    echo "Nim Package Analyzer v" & VERSION
    return
  
  if config.paths.len == 0:
    stderr.writeLine("Error: No paths specified. Use --help for usage information.")
    quit(1)
  
  var allPaths: seq[string] = @[]
  
  for path in config.paths:
    if not dirExists(path):
      stderr.writeLine("Warning: Directory does not exist: " & path)
      continue
    
    if config.recursive:
      let packages = findPackagesRecursive(path)
      if packages.len == 0:
        stderr.writeLine("Warning: No packages found in: " & path)
      else:
        allPaths.add(packages)
    else:
      allPaths.add(path)
  
  if allPaths.len == 0:
    stderr.writeLine("Error: No valid directories found to analyze")
    quit(1)
  
  var packageInfos: seq[PackageInfo] = @[]
  let totalStartTime = cpuTime()
  
  for path in allPaths:
    let info = analyzePackage(path)
    packageInfos.add(info)
    
    if config.verbose and config.outputFormat != ofJson:
      stderr.writeLine("Analyzed: " & info.name & " (" & $(round(info.analysisTime * 1000, 2)) & "ms)")
  
  let totalTime = cpuTime() - totalStartTime
  
  if config.verbose and config.outputFormat != ofJson:
    stderr.writeLine("Total analysis time: " & $(round(totalTime * 1000, 2)) & "ms")
    stderr.writeLine("")

  case config.outputFormat:
  of ofJson:
    outputJson(packageInfos, config)
  of ofTable:
    outputTable(packageInfos, config)
  of ofSummary:
    outputSummary(packageInfos, config)

when isMainModule:
  main()
