#!/bin/bash

# #############################################################################
# SQLite Benchmark Automation Script (Serial, Averaged, with System Tuning)
# #############################################################################

set -e
set -o pipefail

# --- Restore Function and Trap ---
# This function is called on exit to restore original system settings.
function restore_settings() {
  echo
  echo "--- Restoring original system settings... ---"

  # Restore CPU governors
  if [ ${#a_cpu_governors[@]} -gt 0 ]; then
    echo "Restoring original CPU governors for all CPUs"
    for cpu_path in "${!a_cpu_governors[@]}"; do
      echo "${a_cpu_governors[$cpu_path]}" | sudo tee "$cpu_path" >/dev/null
    done
  fi

  # Restore Transparent Huge Pages setting
  if [ -n "$s_orig_thp_setting" ] && [ -f "$THP_PATH" ]; then
    echo "Restoring Transparent Hugepage setting to '${s_orig_thp_setting}'"
    echo "$s_orig_thp_setting" | sudo tee "$THP_PATH" >/dev/null
  fi

  # Restore swap
  if [ ${#a_orig_swap_devices[@]} -gt 0 ]; then
    for swap_device in "${a_orig_swap_devices[@]}"; do
      echo "Re-enabling swap on ${swap_device}"
      sudo swapon "$swap_device"
    done
  fi
  echo "--- System settings restored. ---"
}

# Set a trap to call restore_settings on EXIT, INT, or TERM signals.
trap restore_settings EXIT INT TERM

# --- Configuration ---
BENCHMARK_EXEC="./sqlite_benchmark"
BENCHMARKS_TO_RUN="fillrandom,readrandom"
declare -a SIZES=(
    "100MB,25600,4096"
    "1GB,262144,4096"
)
declare -a STORAGE_CONFIGS=(
    "memory,:memory:"
    "tmpfs,/tmp/test.db"
    "nvme,/db/test.db"
    "pmem,/mnt/pmem/test.db"
)
declare -a PRAGMA_CONFIGS=(
    "defaults,"
    "tuned_no_mmap,journal_mode=WAL,synchronous=NORMAL,mmap_size=0"
    "tuned_with_mmap,journal_mode=WAL,synchronous=NORMAL,mmap_size=__MMAP_SIZE__"
)
THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"

# --- Argument Parsing ---
NUM_RUNS=3
for arg in "$@"; do
  case $arg in
    --runs=*)
      NUM_RUNS="${arg#*=}"
      shift
      ;;
  esac
done

# --- System Tuning ---
echo "--- Applying system tuning for benchmarks... ---"

# Request sudo credentials upfront
if ! sudo -v; then
  echo "Error: sudo credentials required for system tuning." >&2
  exit 1
fi

# 1. Save and set CPU governors
declare -A a_cpu_governors
echo "Setting CPU governors to 'performance' for all CPUs"
for cpu_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  a_cpu_governors["$cpu_path"]=$(cat "$cpu_path")
  echo "performance" | sudo tee "$cpu_path" >/dev/null
done

# 2. Save and disable Transparent Huge Pages
s_orig_thp_setting=""
if [ -f "$THP_PATH" ]; then
  s_orig_thp_setting=$(cat "$THP_PATH" | awk '{print $1}' | sed 's/\[//g; s/\]//g')
  echo "Disabling Transparent Hugepages (original setting: '$s_orig_thp_setting')"
  echo "never" | sudo tee "$THP_PATH" >/dev/null
fi

# 3. Save and disable swap
declare -a a_orig_swap_devices
a_orig_swap_devices=($(swapon --show=NAME --noheadings))
if [ ${#a_orig_swap_devices[@]} -gt 0 ]; then
  echo "Disabling swap on all devices: ${a_orig_swap_devices[*]}"
  sudo swapoff -a
fi
echo "--- System tuning complete. ---"
echo

# --- Script Setup ---
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTS_DIR="results_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"
echo "SQLite Benchmark Suite (Serial Execution, Averaged over $NUM_RUNS runs)"
echo "=================================================================="
echo "Results will be stored in: ${RESULTS_DIR}"
echo

# --- Main Execution Loop ---
for size_config in "${SIZES[@]}"; do
    IFS=',' read -r size_name num_entries value_size <<< "$size_config"
    db_size_bytes=$((num_entries * value_size))
    mmap_size=$((db_size_bytes + db_size_bytes / 10))

    for storage_config in "${STORAGE_CONFIGS[@]}"; do
        IFS=',' read -r storage_name db_path <<< "$storage_config"
        # ... (rest of the script is identical to the previous version)
        if [[ "$db_path" != ":memory:" ]] && [ ! -d "$(dirname "$db_path")" ]; then continue; fi

        for pragma_config in "${PRAGMA_CONFIGS[@]}"; do
            IFS=',' read -r pragma_name pragma_template <<< "$pragma_config"
            if [[ "$storage_name" == "memory" ]] && [[ "$pragma_name" == *"mmap"* ]]; then
                echo "--> SKIPPING mmap test for in-memory database."
                continue
            fi

            final_pragma_string="${pragma_template/__MMAP_SIZE__/$mmap_size}"
            LOG_FILE="${RESULTS_DIR}/${storage_name}_${size_name}_${pragma_name}.log"

            echo "----------------------------------------------------------------"
            echo "RUNNING: Size=${size_name}, Storage=${storage_name}, PRAGMA=${pragma_name} ($NUM_RUNS times)"

            declare -A ops_sum
            declare -A run_counts

            for i in $(seq 1 $NUM_RUNS); do
                echo "    Run $i/$NUM_RUNS..."
                
                # Drop caches before each run for consistency
                echo "    -> Dropping caches..."
                echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
                
                command_args=(
                    "--db_path" "$db_path"
                    "--num" "$num_entries"
                    "--value_size" "$value_size"
                    "--benchmarks" "$BENCHMARKS_TO_RUN"
                    "--pragmas" "$final_pragma_string"
                )
                output=$("$BENCHMARK_EXEC" "${command_args[@]}")
                while read -r line; do
                    if [[ "$line" == *"ops/sec"* ]]; then
                        local_benchmark=$(echo "$line" | awk '{print $1}')
                        local_ops=$(echo "$line" | awk '{print $3}')
                        [[ -z "${ops_sum[$local_benchmark]}" ]] && ops_sum[$local_benchmark]=0
                        [[ -z "${run_counts[$local_benchmark]}" ]] && run_counts[$local_benchmark]=0
                        ops_sum[$local_benchmark]=$(echo "${ops_sum[$local_benchmark]} + $local_ops" | bc)
                        run_counts[$local_benchmark]=$((run_counts[$local_benchmark] + 1))
                    fi
                done <<< "$output"
            done

            echo "Averaging results and writing to log: ${LOG_FILE}"
            {
              echo "--- Benchmark Configuration ---"
              echo "Database path: $db_path"
              echo "Entries:       $num_entries"
              echo "Value Size:    $value_size bytes"
              echo "PRAGMAs:       ${final_pragma_string:-[defaults]}"
              echo "-----------------------------"
              for benchmark_name in "${!ops_sum[@]}"; do
                  total_ops=${ops_sum[$benchmark_name]}
                  count=${run_counts[$benchmark_name]}
                  if [[ $count -gt 0 ]]; then
                    average_ops=$(echo "scale=2; $total_ops / $count" | bc)
                    printf "%-20s: %s ops/sec (averaged over %d runs)\n" "$benchmark_name" "$average_ops" "$count"
                  fi
              done
            } > "$LOG_FILE"
            
            echo "COMPLETED: ${storage_name}_${size_name}_${pragma_name}"
            echo "----------------------------------------------------------------"
            echo
        done
    done
done

# --- Results Parsing and Comparison ---
# This final section is also identical to the previous version
echo
echo "==========================="
echo "Benchmark Summary Report"
echo "==========================="
echo

SUMMARY_FILE="${RESULTS_DIR}/summary_report.txt"
printf "%-20s | %-10s | %-20s | %-20s | %-15s\n" "Storage" "Size" "PRAGMA Setup" "Benchmark" "Ops/sec" | tee -a "$SUMMARY_FILE"
echo "----------------------------------------------------------------------------------------------------" | tee -a "$SUMMARY_FILE"

find "$RESULTS_DIR" -name "*.log" -print0 | while IFS= read -r -d $'\0' logfile; do
    filename=$(basename "$logfile" .log)
    IFS='_' read -r storage size pragma <<< "$filename"
    awk -v storage="$storage" -v size="$size" -v pragma="$pragma" '
        /ops\/sec/ {
            benchmark = $1;
            gsub(/:/, "", benchmark);
            ops_sec = $3;
            printf "%-20s | %-10s | %-20s | %-20s | %-15s\n", storage, size, pragma, benchmark, ops_sec;
        }
    ' "$logfile" | tee -a "$SUMMARY_FILE"
done

echo
echo "Comparison report saved to: ${SUMMARY_FILE}"
echo "Benchmark suite finished."

# Add after the summary is generated
echo "Generating performance chart..."
./plot_results.sh "${SUMMARY_FILE}"
