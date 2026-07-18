---
name: analyze-project
description: Perform a comprehensive analysis of the current project including scope, functionality, architecture, data flow, execution flow, strengths, weaknesses, and suggest next features.
allowed-tools: Bash, Read, Glob, Grep, Agent, WebFetch, WebSearch
argument-hint: "[optional focus area]"
---

# Comprehensive Project Analysis

You MUST perform a thorough, end-to-end analysis of the current project and produce a COMPLETE report covering every section listed below. No section may be omitted, abbreviated, or deferred. If an optional focus area is provided, give it extra depth, but NEVER at the expense of other sections: $ARGUMENTS

## Critical Rules

1. **Every section is mandatory.** You must produce substantive content for ALL 9 report sections. Never say "not applicable" without concrete justification from the codebase.
2. **Evidence-based.** Every claim must cite specific files, classes, functions, or line numbers (e.g., `src/core/engine.cpp:42`). Do not make vague or unsupported statements.
3. **Investigate before writing.** You must complete ALL investigation phases below BEFORE writing the report. Do not start writing the report until you have gathered sufficient evidence for every section.
4. **Full report at the end.** After all investigation is complete, output the ENTIRE report as a single cohesive document. Do not output partial reports or section-by-section incremental results.

## Phase 1: Investigation

Complete every step below. Use the Explore agent (via the Agent tool with subagent_type=Explore) for broad searches and direct Read/Glob/Grep for targeted lookups. Launch parallel agents where steps are independent.

### Step 1 — Project Identity & Build System
- Read README, CHANGELOG, LICENSE, and the primary build config (CMakeLists.txt, Cargo.toml, package.json, pyproject.toml, etc.)
- Determine: project name, language(s), version, license, stated purpose

### Step 2 — Directory Structure & Module Map
- List top-level directories and key subdirectories
- Identify the source tree layout: where is library code, application code, tests, docs, CI config, examples?

### Step 3 — Public API Surface & Entry Points
- Find main() or equivalent entry points
- Identify the public API: exported headers, public modules, CLI commands, REST endpoints, or SDK surface
- Note how the library/application is consumed by users

### Step 4 — Core Architecture & Design Patterns
- Read the central abstractions, interfaces, and base classes
- Identify the architectural pattern (layered, hexagonal, plugin-based, etc.)
- Document design patterns in use (factory, builder, observer, RAII, type erasure, CRTP, etc.)
- Map the dependency graph between major components

### Step 5 — Data Flow Analysis
- Trace how data enters the system (user input, API, DB, files, network)
- Follow the transformation pipeline: parsing, validation, mapping, query building, serialization
- Identify the storage layer: databases, caches, file system, in-memory structures
- Trace how data exits: responses, output, side effects, logging
- Check for schema management, migrations, or code generation

### Step 6 — Execution Flow Analysis
- Trace the initialization / startup sequence
- Identify the main execution loop, request pipeline, or command dispatch
- Document the threading model, concurrency primitives, or async patterns
- Trace error propagation: how errors are created, transformed, and surfaced
- Identify shutdown / cleanup / resource release behavior

### Step 7 — Performance Deep Dive
- Identify hot paths: the most frequently executed code paths in normal operation
- Analyze memory allocation patterns: heap vs stack, smart pointer usage, object lifetimes, pool allocators
- Check for copy vs move semantics: are large objects moved where possible? Are unnecessary copies present?
- Review data structure choices: are the chosen containers appropriate for their access patterns (vector vs list vs map vs unordered_map)?
- Look for compile-time computation: constexpr usage, template metaprogramming, static dispatch vs dynamic dispatch
- Analyze I/O patterns: buffering strategies, batching, connection pooling, prepared statement caching
- Search for existing benchmarks, performance tests, or profiling infrastructure
- Identify string handling patterns: std::string vs std::string_view, unnecessary allocations, format string usage
- Check for cache-friendliness: data layout, struct packing, sequential vs random access patterns
- Look for algorithmic complexity issues: O(n^2) loops, redundant lookups, unbounded growth

### Step 8 — Test Suite & Quality
- Find the test framework and test directory structure
- Assess test coverage: which modules have tests, which do not
- Identify test categories: unit, integration, end-to-end, performance, fuzz
- Note any test infrastructure: fixtures, helpers, mocks, test databases

### Step 9 — Dependencies & CI/CD
- Review external dependency declarations (package manager files, vcpkg, conan, CMake FetchContent, etc.)
- Identify critical dependencies and their roles
- Check CI/CD: GitHub Actions, Makefiles, Docker, deployment scripts
- Note any dependency risks: outdated, unmaintained, or overly broad

### Step 10 — Documentation Quality
- Assess inline documentation: doc comments, Doxygen, JSDoc, docstrings
- Check for standalone docs: guides, tutorials, API reference, architecture docs
- Identify documentation gaps

## Phase 2: Full Report

After completing ALL investigation steps above, output the complete report below. Every section MUST contain multiple substantive bullet points with file/code citations.

---

# Project Analysis Report

## 1. Project Overview

Cover ALL of the following:
- Project name, stated purpose, and problem domain
- Target audience and user personas
- Language(s), key frameworks, and technologies
- License, version, and maturity level (alpha, beta, stable, maintained)
- Repository structure summary

## 2. Scope & Functionality

Cover ALL of the following:
- Complete feature inventory: enumerate every major capability the project provides today
- Supported platforms, operating systems, databases, protocols, or integrations
- Public API surface: key classes, functions, endpoints, or commands users interact with
- Configuration options, environment variables, and extensibility points (plugins, hooks, callbacks)
- What is explicitly out of scope or unsupported

## 3. Software Architecture

Cover ALL of the following:
- High-level architectural pattern and rationale
- Key modules/components with their responsibilities (name each one, cite directory/files)
- Dependency graph between components (use ASCII diagram if helpful)
- Design patterns identified (cite specific implementations)
- Build system, build targets, and output artifacts
- How the architecture enables or constrains extensibility

## 4. Data Flow

Cover ALL of the following:
- Data entry points: every way data enters the system
- Transformation pipeline: each stage data passes through, with class/function citations
- Storage layer: what is stored, where, and how (schema, serialization format)
- Data exit points: how processed data leaves the system
- Schema management, migrations, or data evolution strategy
- Include an ASCII data flow diagram if the flow has 3+ stages

## 5. Execution Flow

Cover ALL of the following:
- Startup / initialization sequence (what happens in what order)
- Main execution path: the primary operation loop or request handling pipeline
- Threading model: single-threaded, thread pool, async, coroutines — cite the implementation
- Error propagation: how errors are created, carried through layers, and surfaced to users
- Resource management and cleanup: RAII, destructors, finally blocks, shutdown hooks
- Include an ASCII sequence diagram for the primary execution path if it spans 3+ components

## 6. Performance Analysis

This section is mandatory and must be deeply investigated. Cover ALL of the following:

### 6.1 Hot Paths & Critical Code Paths
- Identify the most frequently executed code paths during normal operation
- For each hot path, cite the entry function and the key functions it calls
- Note any performance-sensitive operations: tight loops, frequent allocations, serialization

### 6.2 Memory & Allocation Patterns
- Heap vs stack allocation strategy: where are objects allocated and why?
- Smart pointer usage: shared_ptr vs unique_ptr frequency, reference counting overhead
- Object lifetime management: RAII patterns, pool allocators, arena allocation, custom allocators
- Identify unnecessary copies of large objects — cite specific locations
- Move semantics adoption: are move constructors/assignment operators defined where needed?

### 6.3 Data Structure & Algorithm Choices
- For each major data structure, state what it is, what access pattern it serves, and whether the choice is optimal
- Identify algorithmic complexity of key operations (cite function and its Big-O)
- Flag any O(n^2) or worse patterns, redundant lookups, or linear scans that could use indexing
- Note container reserve/capacity hints usage (or lack thereof)

### 6.4 Compile-Time vs Runtime Computation
- constexpr usage: what is computed at compile time?
- Template metaprogramming or static dispatch patterns
- Dynamic dispatch (virtual functions) frequency and whether it is justified
- String literal handling: compile-time format strings, consteval usage

### 6.5 I/O & Database Performance
- Connection pooling and reuse strategy
- Prepared statement caching or query plan reuse
- Batching and bulk operations: are N+1 query patterns avoided?
- Buffering strategy for file or network I/O
- Serialization/deserialization overhead

### 6.6 String Handling
- std::string vs std::string_view usage — are views used where ownership is not needed?
- String concatenation patterns: std::format vs operator+ vs string streams
- Unnecessary string copies or temporary allocations in hot paths

### 6.7 Concurrency & Synchronization Overhead
- Lock contention points: mutexes, atomics, lock-free structures
- Thread creation/destruction overhead vs thread pooling
- False sharing risks in concurrent data structures
- Async operation overhead: coroutine frame allocations, callback chains

### 6.8 Benchmarks & Profiling Infrastructure
- Existing benchmark suites: what is measured, how, and where are results stored?
- Profiling hooks or instrumentation points
- Performance regression detection in CI
- If no benchmarks exist, state this explicitly and note which operations most need them

### 6.9 Identified Bottlenecks & Optimization Opportunities
- List concrete bottlenecks found during investigation, citing file and line
- For each bottleneck, describe the impact and a potential remediation
- Prioritize by estimated impact (high / medium / low)

---

## 7. Strengths (Strong Arguments for This Project)

Cover ALL of the following:
- Technical merits: performance characteristics, type safety, correctness guarantees, memory safety
- API design quality: ergonomics, consistency, discoverability, documentation
- Code quality: naming conventions, consistency, readability, adherence to idioms
- Test quality: coverage breadth, test rigor, test infrastructure
- Unique selling points: what does this project do better than alternatives in the same space?
- Community, ecosystem, or tooling advantages

## 8. Weaknesses & Risks

Cover ALL of the following. Be direct and specific — do not soften or hedge:
- Missing features or incomplete implementations (cite specific TODOs, stubs, or gaps)
- Architectural limitations or technical debt (cite specific files or patterns)
- Test coverage gaps: which modules or code paths lack tests
- Documentation gaps: what is undocumented or poorly documented
- Dependency risks: outdated, unmaintained, or problematic dependencies
- Scalability or performance concerns (cite evidence or bottleneck locations)
- Security considerations: input validation, injection risks, credential handling
- Portability or compatibility issues
- Onboarding friction: how hard is it for a new contributor to understand and build the project

## 9. Suggested Next Features

Provide at least 5 concrete, actionable feature suggestions. For EACH one, include ALL of the following fields:

| Field | Description |
|---|---|
| **Feature** | Concise title |
| **Description** | What it does and how it works |
| **Rationale** | Why it matters: user demand, competitive parity, technical necessity, or architectural improvement |
| **Complexity** | Low / Medium / High — with brief justification |
| **Prerequisites** | What must exist or change first |
| **Affected components** | Which modules/files would be modified |

Order suggestions by impact-to-effort ratio (highest value first).

---

## Formatting Requirements

- Use markdown headings (`##`, `###`) exactly as shown above
- Use bullet points for all findings within each section
- Include file path references with line numbers (e.g., `src/core/engine.cpp:42`) for every factual claim
- Use fenced code blocks for ASCII diagrams
- Use tables for the feature suggestions in section 9
- Do not use emojis unless the user explicitly requests them
