#!/usr/bin/env bash
SEARCH_PATH="$1"

if [ -z "$SEARCH_PATH" ]; then
    echo "Usage: $0 <path_to_search>"
    exit 1
fi

RERUN_XDS=0
XDSINP_PATTERN="XDS.INP"
IDXREF_PATTERN="IDXREF.LP"
CORRECT_PATTERN="CORRECT.LP"
SPOTS_PATTERN="SPOT.LP"
IDXREF_ERROR="!!! ERROR !!!"
JSON_FILE="xds_results.json"
echo "[" > "$JSON_FILE"
FIRST_ENTRY=1

echo "Looking for XDS files within path: $SEARCH_PATH"

find "$SEARCH_PATH" -type f -iname "*.lp" -exec dirname {} \; 2>/dev/null | sort -u | while read -r folder; do
    echo "--------------------------------------------------------"
    echo "XDS run found in: $folder"

    SPACEGROUP="N/A"
    UNITCELL="N/A"
    ISA="N/A"
    SIZE_FOLDER="N/A"
    NUM_IMAGES="N/A"
    IMAGES_PATH="N/A"
    NAME_FRAMES="N/A"
    IMAGE_CHECK_STATUS="N/A"
    INDEXING_RESULTS="N/A"
    SUBTREE_RESULTS="N/A"


    xdsinp_file="$folder/$XDSINP_PATTERN"
    if [ -f "$xdsinp_file" ]; then
        DATA_RANGE=$(grep -E "^DATA_RANGE=" "$xdsinp_file" 2>/dev/null | head -n 1 | awk -F= '{print $2}')
        start_img=$(echo "$DATA_RANGE" | awk '{print $1}')
        end_img=$(echo "$DATA_RANGE" | awk '{print $2}')
        if [[ -n "$start_img" && -n "$end_img" ]]; then
            NUM_IMAGES=$((end_img - start_img + 1))
        fi
        SPACEGROUP=$(grep -E "^SPACE_GROUP_NUMBER=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | sed 's/!.*//' | tr -d ' ')
        UNITCELL=$(grep -E "^UNIT_CELL_CONSTANTS=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | sed 's/!.*//' | xargs)
        NAME_FRAMES=$(grep -E "^NAME_TEMPLATE_OF_DATA_FRAMES=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    fi

    if [ -n "$NAME_FRAMES" ] && [ "$NAME_FRAMES" != "N/A" ]; then
        img_dir=$(dirname "$NAME_FRAMES")
        img_template=$(basename "$NAME_FRAMES")
        search_pattern=$(echo "$img_template" | tr '?' '*')

        [[ "$img_dir" = /* ]] && resolved_img_dir="$img_dir" || resolved_img_dir="$folder/$img_dir"
        if [ -d "$resolved_img_dir" ]; then
            IMAGES_PATH=$(realpath "$resolved_img_dir" 2>/dev/null)
            ACTUAL_IMAGES_COUNT=$(find "$IMAGES_PATH" -maxdepth 1 -type f -name "$search_pattern" 2>/dev/null | wc -l)
            if [ "$NUM_IMAGES" != "N/A" ]; then
                if [ "$ACTUAL_IMAGES_COUNT" -eq "$NUM_IMAGES" ]; then
                    IMAGE_CHECK_STATUS="MATCH ($ACTUAL_IMAGES_COUNT files found)"
                else
                    IMAGE_CHECK_STATUS="MISMATCH (Expected $NUM_IMAGES, found $ACTUAL_IMAGES_COUNT)"
                fi
            else
                IMAGE_CHECK_STATUS="MISMATCH (Expected unknown, found $ACTUAL_IMAGES_COUNT)"
            fi
        else
          IMAGE_CHECK_STATUS="MISMATCH (Expected $NUM_IMAGES, directory not found)"
        fi
    fi

    correct_file="$folder/$CORRECT_PATTERN"
    if [ -f "$correct_file" ]; then
        sg_match=$(grep "SPACE_GROUP_NUMBER=" "$correct_file" 2>/dev/null | tail -n 1 | awk -F= '{print $2}' | tr -d ' ')
        [ -n "$sg_match" ] && SPACEGROUP="$sg_match"

        uc_match=$(grep "UNIT_CELL_CONSTANTS=" "$correct_file" 2>/dev/null | tail -n 1 | awk -F= '{print $2}' | sed 's/!.*//' | xargs)
        [ -n "$uc_match" ] && UNITCELL="$uc_match"

        isa_match=$(awk '/^[ \t]*a[ \t]*b[ \t]*ISa/{getline; print $3}' "$correct_file" 2>/dev/null | tail -n 1)
        [ -n "$isa_match" ] && ISA="$isa_match"
    fi

    idxref_file="$folder/$IDXREF_PATTERN"
    percent_indexed=100
    subtree_ratio=0
    if [ -f "$idxref_file" ]; then
        if grep -q "$IDXREF_ERROR" "$idxref_file" 2>/dev/null; then
          INDEXING_RESULTS=$(awk -v err="$IDXREF_ERROR" '$0 ~ err {flag=1} flag {print}' "$idxref_file" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed 's/"/\\"/g' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        else
          indexed_info=$(grep "SPOTS INDEXED" "$idxref_file" 2>/dev/null | tail -n 1)
          if [ -n "$indexed_info" ]; then
              total_spots=$(echo "$indexed_info" | awk '{print $4}')
              indexed_spots=$(echo "$indexed_info" | awk '{print $1}')
              if [[ "$total_spots" =~ ^[0-9]+$ ]] && [ "$total_spots" -gt 0 ]; then
                  percent_indexed=$(( 100 * indexed_spots / total_spots ))
                  INDEXING_RESULTS="$indexed_spots of $total_spots ($percent_indexed% spots indexed)"
              fi
          fi

          num_subtrees_line=$(grep "NUMBER OF SUBTREES" "$idxref_file" 2>/dev/null | tail -n 1)
          if [ -n "$num_subtrees_line" ]; then
              NUM_SUBTREES=$(echo "$num_subtrees_line" | awk '{print $NF}')
              if [[ "$NUM_SUBTREES" =~ ^[0-9]+$ ]] && [ "$NUM_SUBTREES" -ge 1 ]; then
                  read sub1 sub2 < <(awk '/SUBTREE[ \t]+POPULATION/{
                      while(getline > 0) {
                          if ($1 == "1") s1=$2;
                          if ($1 == "2") s2=$2;
                          if ($1 == "3" || $0 ~ /NUMBER OF ACCEPTED/) break;
                      }
                      # Fallback to "0" if s1 or s2 are empty to prevent bash read errors
                      print (s1==""?"0":s1), (s2==""?"0":s2);
                      exit;
                  }' "$idxref_file")

                  # Handle the 1 subtree case vs multiple subtrees
                  if [ "$NUM_SUBTREES" -eq 1 ]; then
                      SUBTREE_RESULTS="sub1 $sub1"
                      echo "  Subtree      : $SUBTREE_RESULTS"
                  elif [ "$NUM_SUBTREES" -gt 1 ]; then
                      if [[ "$sub1" -gt 0 ]]; then
                          subtree_ratio=$(( 100 * sub2 / sub1 ))
                          SUBTREE_RESULTS="sub1 $sub1 | sub2 $sub2"
                          echo "  Subtree      : $SUBTREE_RESULTS"
                      fi
                  fi
              fi
          fi
        fi
    fi
    echo "  Space Group  : ${SPACEGROUP:-N/A}"
    echo "  Unit Cell    : ${UNITCELL:-N/A}"
    echo "  Images check : ${IMAGE_CHECK_STATUS:-N/A}"
    echo "  Images path  : ${NAME_FRAMES:-N/A}"
    echo "  ISa          : ${ISA:-N/A}"
    echo "  Indexing     : ${INDEXING_RESULTS:-N/A}"
    echo "  Subtree      : ${SUBTREE_RESULTS:-N/A}"

    if [ $FIRST_ENTRY -eq 1 ]; then
        FIRST_ENTRY=0
    else
        echo "," >> "$JSON_FILE"
    fi
    cat <<EOF >> "$JSON_FILE"
    {
        "xds_run_path": "$folder",
        "space_group": "$SPACEGROUP",
        "unit_cell": "$UNITCELL",
        "images_check": "$IMAGE_CHECK_STATUS",
        "images_path": "$NAME_FRAMES",
        "isa": "$ISA",
        "indexing": "$INDEXING_RESULTS",
        "subtree": "$SUBTREE_RESULTS"
    }
EOF
done

# Close the JSON array
echo "" >> "$JSON_FILE"
echo "]" >> "$JSON_FILE"
echo "--------------------------------------------------------"
echo "Search complete."