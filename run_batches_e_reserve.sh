#!/bin/bash

# Usage: ./run_batches.sh <initial_day> <final_day> <num_instances> <input_folder> <output_folder>
# Example: ./run_batches.sh 1 365 8 RTS-GMLC_v2.4.2 RTS-GMLC_v24.1su

INITIAL_DAY=$1
FINAL_DAY=$2
NUM_INSTANCES=$3
INPUT_FOLDER=$4
OUTPUT_FOLDER=$5

# Generate the list of days
DAYS=()
for ((d=INITIAL_DAY; d<=FINAL_DAY; d++)); do
    DAYS+=($d)
done

# Split DAYS into batches
function split_days() {
    local -n arr=$1
    local n=$2
    local total=${#arr[@]}
    local batch_size=$(( (total + n - 1) / n ))
    local batches=()
    for ((i=0; i<total; i+=batch_size)); do
        batch=("${arr[@]:i:batch_size}")
        batches+=("$(IFS=,; echo "${batch[*]}")")
    done
    echo "${batches[@]}"
}

BATCHES=()
read -ra BATCHES <<< "$(split_days DAYS $NUM_INSTANCES)"

for ((i=0; i<${#BATCHES[@]}; i++)); do
    batch_days=(${BATCHES[$i]})
    days_arg="["
    for day in "${batch_days[@]}"; do
        days_arg+="$day,"
    done
    days_arg="${days_arg%,}]"

    echo "Starting batch $((i+1)) with days: ${days_arg}"

    julia --project=. -e "
        include(\"main.jl\");
        generate_ed_solutions(
            days = $days_arg,
            day_µ_configurations_file = \"configuration_e_reserves\",
            input_folder = \"./input/$INPUT_FOLDER\",
            output_folder = \"./output/$OUTPUT_FOLDER\",
            energy_reserve = true,
            set_storage_inflows = true,
            write_post_processing_files = false,
        )
    " &
done

wait
echo "All Julia batch jobs finished."