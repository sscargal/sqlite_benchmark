# SQLite Performance Benchmark Suite

This project provides a powerful and flexible C++ benchmark tool and an automation script to test the performance of SQLite3 across a wide variety of scenarios, storage backends, and system configurations.

It is designed for developers and system administrators who need to measure and compare the I/O performance of SQLite on different hardware (DRAM, NVMe, Persistent Memory) and under various tuning parameters. The suite automatically handles system tuning, result collection, and reporting, making it easy to generate reproducible performance data.

## Features

-   **Comprehensive Benchmark Scenarios**: Test sequential writes, random writes, sequential reads, random reads, and mixed read/write workloads.
-   **Flexible Storage Backends**: Easily benchmark databases running entirely in-memory (`:memory:`), on `tmpfs`, or on any file system path (e.g., `/db` for NVMe, `/mnt/pmem` for Persistent Memory).
-   **Advanced `mmap` Testing**: Directly compare the performance of using `mmap` vs. standard read/write I/O, especially on DAX-enabled file systems like PMem.
-   **Custom PRAGMA Support**: Pass any combination of SQLite PRAGMA commands at runtime to fine-tune database behavior (e.g., `journal_mode`, `synchronous`).
-   **Automated Test Runner**: A powerful `bash` script that runs a matrix of configured tests (storage x size x PRAGMAs).
-   **System-Level Tuning**: The script automatically:
    -   Sets the CPU governor to `performance`.
    -   Disables Transparent Huge Pages (THP) and `swap`.
    -   Drops system caches before each run for "cold" cache testing.
    -   **Safely restores all original settings** on exit or interruption.
-   **Stable, Averaged Results**: Each benchmark configuration is run multiple times (default: 3) to calculate a stable average, reducing the impact of system jitter.
-   **Organized Reporting**: Generates a unique, timestamped directory for each test suite run, with detailed logs and a final, easy-to-parse summary report.
    

## 1. Prerequisites

Before you begin, ensure your system has the following tools installed.

-   A C++17 compliant compiler (e.g., `g++`).
-   The SQLite3 development library (`libsqlite3-dev`).
-   The `bc` command-line calculator (for averaging results).
    
On Debian/Ubuntu, you can install them with:

```bash
sudo apt-get update
sudo apt-get install -y build-essential libsqlite3-dev bc
```

## 2. Setup and Compilation

Follow these steps to compile the C++ benchmark tool.

**Step 1: Get the Source Code**

Clone this repository or ensure you have `sqlite_benchmark.cc` and `run_all_benchmarks.sh` in the same directory.

**Step 2: Download `cxxopts.hpp`**

The C++ tool uses this header-only library for command-line parsing. Download it into your project directory.

```bash
wget https://raw.githubusercontent.com/jarro2783/cxxopts/master/include/cxxopts.hpp
```

**Step 3: Compile the Benchmark Tool**

Use `g++` to compile the C++ source file. The `-O2` flag enables optimizations.

```bash
g++ -std=c++17 -O2 -o sqlite_benchmark sqlite_benchmark.cc -lsqlite3
```

You should now have an executable file named `sqlite_benchmark`.

## 3. How to Run the Benchmark Suite

The easiest way to run a comprehensive set of tests is with the `run_all_benchmarks.sh` script.

**Step 1: Make the Script Executable**

```bash
chmod +x run_all_benchmarks.sh
```

**Step 2: Customize the Test Matrix (Optional)**

Open `run_all_benchmarks.sh` and edit the configuration arrays at the top to define your test matrix:

-   `SIZES`: Define the database sizes to test.
-   `STORAGE_CONFIGS`: Define the storage paths and friendly names.
-   `PRAGMA_CONFIGS`: Define the PRAGMA configurations to test.
-   `BENCHMARKS_TO_RUN`: Define which C++ benchmarks to execute.
    

**Step 3: Run the Suite**

The script requires `sudo` privileges for system tuning and will prompt for a password if necessary.

```bash
# Run with default settings (3 runs per test)
sudo ./run_all_benchmarks.sh

# Specify a different number of runs for averaging
sudo ./run_all_benchmarks.sh --runs=5
```

The script will:

1.  Save your current system settings.
2.  Apply performance tuning.
3.  Run through every combination of tests defined in the configuration.
4.  Generate a summary report.
5.  **Automatically restore your original system settings.**
    

## 4. Manual Execution Examples

You can also run the compiled `sqlite_benchmark` executable directly for quick, specific tests. This is useful for debugging or one-off comparisons.

#### Example 1: In-Memory Database

Test a 100,000-entry random write and random read benchmark running entirely in RAM.

```bash
./sqlite_benchmark --db_path=":memory:" --num=100000 --benchmarks="fillrandom,readrandom"
```

#### Example 2: Test on NVMe with WAL Mode

Run a 1 million entry test on an NVMe drive, with `journal_mode=WAL` and `synchronous=NORMAL`.

```bash
./sqlite_benchmark \
  --db_path="/db/test.db" \
  --num=1000000 \
  --benchmarks="fillseq,readrandom" \
  --pragmas="journal_mode=WAL,synchronous=NORMAL"
```

#### Example 3: Compare `mmap` vs. no-`mmap` on PMem

This is a core use case for the tool.

**A) Without `mmap` (using standard read/write):**

```bash
./sqlite_benchmark \
  --db_path="/mnt/pmem/test.db" \
  --num=1000000 \
  --value_size=4096 \
  --benchmarks="readrandom" \
  --pragmas="journal_mode=WAL,mmap_size=0"
```

**B) With `mmap` enabled (e.g., 4GB):**

```bash
./sqlite_benchmark \
  --db_path="/mnt/pmem/test.db" \
  --num=1000000 \
  --value_size=4096 \
  --benchmarks="readrandom" \
  --pragmas="journal_mode=WAL,mmap_size=4294967296"
```

## 5. Understanding the Output

The automation script creates a timestamped directory (e.g., `results_2025-07-20_17-28-00/`). Inside, you will find:

1.  **Individual Log Files**: A separate `.log` file for each test permutation (e.g., `pmem_1GB_tuned_with_mmap.log`). These contain the averaged result for that specific configuration.
    
2.  **Summary Report**: A file named `summary_report.txt` that aggregates all results into a single, easy-to-compare table.
    

**Example `summary_report.txt`:**

```text
===========================
Benchmark Summary Report
===========================

Storage              | Size       | PRAGMA Setup         | Benchmark            | Ops/sec
----------------------------------------------------------------------------------------------------
memory               | 100MB      | defaults             | fillrandom           | 450112.33
memory               | 100MB      | defaults             | readrandom           | 980225.10
pmem                 | 1GB        | tuned_no_mmap        | fillrandom           | 150432.88
pmem                 | 1GB        | tuned_no_mmap        | readrandom           | 298711.05
pmem                 | 1GB        | tuned_with_mmap      | fillrandom           | 180995.41
pmem                 | 1GB        | tuned_with_mmap      | readrandom           | 550123.72
nvme                 | 1GB        | tuned_with_mmap      | fillrandom           | 95123.45
nvme                 | 1GB        | tuned_with_mmap      | readrandom           | 180654.91
```

## 6. Available Benchmark Scenarios

The C++ tool includes the following benchmarks, which can be specified in the `BENCHMARKS_TO_RUN` variable or with the `--benchmarks` flag.

| Name | Description | Best For Measuring |
|---|---|---|
| fillseq | Sequential Writes: Inserts records in primary key order (0, 1, 2...). | Bulk-loading speed and raw sequential write throughput. |
| fillrandom | Random Writes: Inserts records with random keys. | B-tree performance, page splits, and random write I/O. |
| readseq | Sequential Reads: Reads the entire table in primary key order (SELECT * FROM ... ORDER BY key). | Full table scan speed and sequential read throughput. |
| readrandom | Random Reads: Performs point queries for random keys. | Indexing performance and random read I/O latency. |
| readwrite | Mixed Workload: A 50/50 mix of random reads and random writes within a single transaction. | Realistic application throughput under contention. |

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
