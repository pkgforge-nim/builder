package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

type TargetInfo struct {
	OS       string `json:"os"`
	CPU      string `json:"cpu"`
	Verified bool   `json:"verified"`
	Source   string `json:"source"`
	Command  string `json:"command"`
}

type TargetsResult struct {
	Targets         []TargetInfo `json:"targets"`
	TotalCount      int          `json:"total_count"`
	VerifiedCount   int          `json:"verified_count"`
	DetectedCount   int          `json:"detected_count"`
	HardcodedCount  int          `json:"hardcoded_count"`
	GeneratedAt     string       `json:"generated_at"`
	VerificationRun bool         `json:"verification_run"`
	NimAvailable    bool         `json:"nim_available"`
}

type TargetScanner struct {
	// Regex patterns for extracting targets from help output
	targetListPatterns []*regexp.Regexp
	cleanupPatterns    []*regexp.Regexp
	
	// Known hardcoded targets - updated lists
	knownOSes  []string
	knownCPUs  []string
	
	// Options
	verifyAll      bool
	skipVerify     bool
	hardcodedOnly  bool
	timeout        time.Duration
	nimAvailable   bool
}

func NewTargetScanner() *TargetScanner {
	return &TargetScanner{
		targetListPatterns: []*regexp.Regexp{
			// Patterns to find lines containing target lists
			regexp.MustCompile(`(?i)(available|valid|supported)\s+.*?(?:options|targets|platforms).*?[:]\s*(.+)`),
			regexp.MustCompile(`(?i)one\s+of[:]\s*(.+)`),
			regexp.MustCompile(`(?i)(?:options|targets)\s+are[:]\s*(.+)`),
			regexp.MustCompile(`(?i)--(?:os|cpu)[:]\s*(.+)`),
			// Match lines that list targets with common separators
			regexp.MustCompile(`(?i)(?:^|\s)([a-z0-9_]+(?:[,\s|;]+[a-z0-9_]+){3,})`),
		},
		cleanupPatterns: []*regexp.Regexp{
			// Remove noise words and characters
			regexp.MustCompile(`\b(?:or|and|the|a|an|options|are|targets|platforms|available|supported|valid|one|of)\b`),
			regexp.MustCompile(`[:\.,;]+`),
			regexp.MustCompile(`\s+`),
		},
		// Updated OS list from Nim documentation
		knownOSes: []string{
			"dos", "windows", "os2", "linux", "morphos", "skyos", "solaris", 
			"irix", "netbsd", "freebsd", "openbsd", "dragonfly", "crossos", 
			"aix", "palmos", "qnx", "amiga", "atari", "netware", "macos", 
			"macosx", "ios", "haiku", "android", "vxworks", "genode", "js", 
			"nimvm", "standalone", "nintendoswitch", "freertos", "zephyr", 
			"nuttx", "any",
		},
		// Updated CPU list from Nim documentation
		knownCPUs: []string{
			"i386", "m68k", "alpha", "powerpc", "powerpc64", "powerpc64el", 
			"sparc", "vm", "hppa", "ia64", "amd64", "mips", "mipsel", "arm", 
			"arm64", "js", "nimvm", "avr", "msp430", "sparc64", "mips64", 
			"mips64el", "riscv32", "riscv64", "esp", "wasm32", "e2k", 
			"loongarch64",
		},
		timeout: 30 * time.Second,
	}
}

func (ts *TargetScanner) checkNimAvailable() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	cmd := exec.CommandContext(ctx, "nim", "--version")
	err := cmd.Run()
	return err == nil
}

func (ts *TargetScanner) parseHelpOutput(output string, targetType string) []string {
	var results []string
	seen := make(map[string]bool)
	
	lines := strings.Split(output, "\n")
	
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		
		// Try each pattern to extract target lists
		for _, pattern := range ts.targetListPatterns {
			matches := pattern.FindStringSubmatch(line)
			if len(matches) > 1 {
				// Use the last capture group
				targetStr := matches[len(matches)-1]
				targets := ts.extractTargetsFromString(targetStr)
				
				for _, target := range targets {
					if !seen[target] && ts.isValidTargetName(target, targetType) {
						results = append(results, target)
						seen[target] = true
					}
				}
			}
		}
	}
	
	return results
}

func (ts *TargetScanner) extractTargetsFromString(input string) []string {
	// Clean up the input string
	input = strings.ToLower(strings.TrimSpace(input))
	
	// Apply cleanup patterns
	for _, pattern := range ts.cleanupPatterns {
		input = pattern.ReplaceAllString(input, " ")
	}
	
	// Try different separators
	separators := []string{", ", " ", ",", "|", ";", "\t"}
	var targets []string
	
	for _, sep := range separators {
		if strings.Contains(input, sep) {
			parts := strings.Split(input, sep)
			if len(parts) > 2 { // Must have multiple targets
				for _, part := range parts {
					part = strings.TrimSpace(part)
					if part != "" && len(part) > 1 {
						targets = append(targets, part)
					}
				}
				break
			}
		}
	}
	
	// If no separators worked, try whitespace splitting
	if len(targets) == 0 {
		words := strings.Fields(input)
		if len(words) > 2 {
			targets = words
		}
	}
	
	return targets
}

func (ts *TargetScanner) isValidTargetName(name, targetType string) bool {
	// Basic validation for target names
	if len(name) < 2 || len(name) > 20 {
		return false
	}
	
	// Must contain only alphanumeric characters, underscores, and digits
	validName := regexp.MustCompile(`^[a-z0-9_]+$`)
	if !validName.MatchString(name) {
		return false
	}
	
	// Check against known patterns for OS/CPU names
	if targetType == "os" {
		osPattern := regexp.MustCompile(`^(linux|windows|macos|freebsd|android|ios|.*bsd|.*nix|.*os)$|^[a-z]+$`)
		return osPattern.MatchString(name)
	} else if targetType == "cpu" {
		cpuPattern := regexp.MustCompile(`^(i386|amd64|x86|arm|mips|sparc|powerpc|riscv|wasm|alpha).*$|^[a-z0-9]+$`)
		return cpuPattern.MatchString(name)
	}
	
	return true
}

func (ts *TargetScanner) tryNimQuery(queryType string) []string {
	if !ts.nimAvailable {
		return nil
	}
	
	commands := [][]string{
		// Primary methods - trigger help by invalid options
		{"--" + queryType + ":invalid", "c"},
		{"--" + queryType + ":help", "c"},
		{"--" + queryType + ":?", "c"},
		// Secondary methods - general help
		{"--help"},
		{"-h"},
		{"help"},
		// Tertiary methods - version and dump info
		{"--version"},
		{"-v"},
		{"dump", "--dump.format:json", "dummy"},
	}
	
	for _, args := range commands {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		cmd := exec.CommandContext(ctx, "nim", args...)
		
		output, err := cmd.CombinedOutput()
		cancel()
		
		if err == nil || len(output) > 0 {
			parsed := ts.parseHelpOutput(string(output), queryType)
			if len(parsed) > 0 {
				log.Printf("Found %d targets for %s using command: nim %s", 
					len(parsed), queryType, strings.Join(args, " "))
				return parsed
			}
		}
	}
	
	return nil
}

func (ts *TargetScanner) verifyTarget(osName, cpu string) bool {
	if !ts.nimAvailable {
		return false
	}
	
	// Create a simple test program
	testContent := `echo "Hello, World!"`
	
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	
	cmd := exec.CommandContext(ctx, "nim", 
		"--os:"+osName, 
		"--cpu:"+cpu, 
		"--compileOnly", 
		"--hints:off", 
		"--warnings:off",
		"-")
	
	cmd.Stdin = strings.NewReader(testContent)
	output, err := cmd.CombinedOutput()
	
	if err != nil {
		return false
	}
	
	outputStr := strings.ToLower(string(output))
	// Check for common error indicators
	errorIndicators := []string{"error:", "invalid", "unknown", "unsupported", "failed"}
	for _, indicator := range errorIndicators {
		if strings.Contains(outputStr, indicator) {
			return false
		}
	}
	
	return true
}

func (ts *TargetScanner) scanTargets() []TargetInfo {
	var targets []TargetInfo
	osSet := make(map[string]string) // os -> source
	cpuSet := make(map[string]string) // cpu -> source
	
	// Check if nim is available
	ts.nimAvailable = ts.checkNimAvailable()
	
	if !ts.nimAvailable {
		log.Println("Warning: 'nim' command not found. Using hardcoded target list only.")
	}
	
	if !ts.hardcodedOnly && ts.nimAvailable {
		log.Println("Attempting to detect targets from nim help output...")
		
		// Method 1: Try to parse from nim help output
		detectedOSes := ts.tryNimQuery("os")
		detectedCPUs := ts.tryNimQuery("cpu")
		
		// Add detected targets
		for _, osName := range detectedOSes {
			osSet[osName] = "detected"
		}
		for _, cpu := range detectedCPUs {
			cpuSet[cpu] = "detected"
		}
		
		log.Printf("Detected %d OSes and %d CPUs from help output", len(detectedOSes), len(detectedCPUs))
	}
	
	// Method 2: Add hardcoded known targets
	log.Println("Adding hardcoded targets...")
	for _, osName := range ts.knownOSes {
		if _, exists := osSet[osName]; !exists {
			osSet[osName] = "hardcoded"
		}
	}
	for _, cpu := range ts.knownCPUs {
		if _, exists := cpuSet[cpu]; !exists {
			cpuSet[cpu] = "hardcoded"
		}
	}
	
	log.Printf("Total unique OSes: %d, CPUs: %d", len(osSet), len(cpuSet))
	
	// Generate all combinations
	var oses, cpus []string
	for osName := range osSet {
		oses = append(oses, osName)
	}
	for cpu := range cpuSet {
		cpus = append(cpus, cpu)
	}
	
	sort.Strings(oses)
	sort.Strings(cpus)
	
	for _, osName := range oses {
		for _, cpu := range cpus {
			source := "hardcoded"
			if osSet[osName] == "detected" && cpuSet[cpu] == "detected" {
				source = "detected"
			} else if osSet[osName] == "detected" || cpuSet[cpu] == "detected" {
				source = "mixed"
			}
			
			targets = append(targets, TargetInfo{
				OS:      osName,
				CPU:     cpu,
				Source:  source,
				Command: fmt.Sprintf("nim --os:%s --cpu:%s", osName, cpu),
			})
		}
	}
	
	return targets
}

func (ts *TargetScanner) verifyTargets(targets []TargetInfo) []TargetInfo {
	if ts.skipVerify || !ts.nimAvailable || ts.hardcodedOnly {
		if ts.skipVerify {
			log.Println("Skipping verification as requested.")
		} else if ts.hardcodedOnly {
			log.Println("Skipping verification - hardcoded-only mode.")
		} else {
			log.Println("Skipping verification - nim command not available.")
		}
		return targets
	}
	
	if !ts.verifyAll {
		commonOSes := map[string]bool{
			"linux": true, "windows": true, "macosx": true, "freebsd": true,
		}
		commonCPUs := map[string]bool{
			"amd64": true, "i386": true, "arm": true, "arm64": true,
		}
		
		log.Println("Verifying common targets...")
		for i := range targets {
			if commonOSes[targets[i].OS] && commonCPUs[targets[i].CPU] {
				targets[i].Verified = ts.verifyTarget(targets[i].OS, targets[i].CPU)
			}
		}
		return targets
	}
	
	log.Printf("Verifying all %d targets (this may take a while)...", len(targets))
	
	const maxWorkers = 8
	semaphore := make(chan struct{}, maxWorkers)
	var wg sync.WaitGroup
	var mu sync.Mutex
	
	for i := range targets {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()
			
			verified := ts.verifyTarget(targets[idx].OS, targets[idx].CPU)
			
			mu.Lock()
			targets[idx].Verified = verified
			mu.Unlock()
			
			if idx%50 == 0 {
				log.Printf("Verified %d/%d targets...", idx+1, len(targets))
			}
		}(i)
	}
	
	wg.Wait()
	log.Println("Verification complete!")
	
	return targets
}

func outputJSON(targets []TargetInfo, scanner *TargetScanner) error {
	verifiedCount := 0
	detectedCount := 0
	hardcodedCount := 0
	
	for _, target := range targets {
		if target.Verified {
			verifiedCount++
		}
		if target.Source == "detected" {
			detectedCount++
		} else if target.Source == "hardcoded" {
			hardcodedCount++
		}
	}
	
	result := TargetsResult{
		Targets:         targets,
		TotalCount:      len(targets),
		VerifiedCount:   verifiedCount,
		DetectedCount:   detectedCount,
		HardcodedCount:  hardcodedCount,
		GeneratedAt:     time.Now().UTC().Format(time.RFC3339),
		VerificationRun: scanner.verifyAll && !scanner.skipVerify,
		NimAvailable:    scanner.nimAvailable,
	}
	
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(result)
}

func outputCSV(targets []TargetInfo) error {
	writer := csv.NewWriter(os.Stdout)
	defer writer.Flush()
	
	// Write header
	if err := writer.Write([]string{"os", "cpu", "verified", "source", "command"}); err != nil {
		return err
	}
	
	// Write data
	for _, target := range targets {
		record := []string{
			target.OS,
			target.CPU,
			fmt.Sprintf("%t", target.Verified),
			target.Source,
			target.Command,
		}
		if err := writer.Write(record); err != nil {
			return err
		}
	}
	
	return nil
}

func outputTable(targets []TargetInfo) error {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	defer w.Flush()
	
	// Write header
	fmt.Fprintln(w, "OS\tCPU\tVerified\tSource\tCommand")
	fmt.Fprintln(w, "──\t───\t────────\t──────\t───────")
	
	// Write data
	for _, target := range targets {
		fmt.Fprintf(w, "%s\t%s\t%t\t%s\t%s\n",
			target.OS, target.CPU, target.Verified, target.Source, target.Command)
	}
	
	return nil
}

func main() {
	var (
		format        = flag.String("format", "json", "Output format: json, csv, or table")
		verifyAll     = flag.Bool("verify-all", false, "Verify all targets (slow)")
		skipVerify    = flag.Bool("skip-verify", false, "Skip verification entirely")
		hardcodedOnly = flag.Bool("hardcoded-only", false, "Use only hardcoded targets (no nim dependency)")
		timeout       = flag.Duration("timeout", 30*time.Second, "Timeout for verification operations")
		help          = flag.Bool("help", false, "Show help")
	)
	
	flag.Parse()
	
	if *help {
		fmt.Println("Usage: nim-targets [options]")
		fmt.Println("\nOptions:")
		flag.PrintDefaults()
		fmt.Println("\nThis tool scans for available Nim compilation targets by:")
		fmt.Println("1. Parsing nim help output using regex patterns (if nim available)")
		fmt.Println("2. Including known hardcoded targets")
		fmt.Println("3. Optionally verifying targets by test compilation")
		fmt.Println("\nNotes:")
		fmt.Println("- If nim command is not found, only hardcoded targets are used")
		fmt.Println("- Use --hardcoded-only to skip nim detection entirely")
		fmt.Println("- Use --skip-verify to skip all verification steps")
		return
	}
	
	// Validate conflicting options
	if *verifyAll && *skipVerify {
		log.Fatal("Cannot use --verify-all and --skip-verify together")
	}
	
	scanner := NewTargetScanner()
	scanner.verifyAll = *verifyAll
	scanner.skipVerify = *skipVerify
	scanner.hardcodedOnly = *hardcodedOnly
	scanner.timeout = *timeout
	
	// Scan for targets
	targets := scanner.scanTargets()
	
	// Verify targets
	targets = scanner.verifyTargets(targets)
	
	// Output results
	switch *format {
	case "json":
		if err := outputJSON(targets, scanner); err != nil {
			log.Fatalf("Error outputting JSON: %v", err)
		}
	case "csv":
		if err := outputCSV(targets); err != nil {
			log.Fatalf("Error outputting CSV: %v", err)
		}
	case "table":
		if err := outputTable(targets); err != nil {
			log.Fatalf("Error outputting table: %v", err)
		}
	default:
		log.Fatalf("Unknown format: %s", *format)
	}
}
