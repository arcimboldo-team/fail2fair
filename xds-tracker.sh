#!/usr/bin/env bash
# This script searches in a drive for XDS files, looks for relevant information
# (like errors, parameters, and stats) and prints the folders/files where they have been found.

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


    xdsinp_file="$folder/$XDSINP_PATTERN"
    if [ -f "$xdsinp_file" ]; then
        DATA_RANGE=$(grep -E "^DATA_RANGE=" "$xdsinp_file" 2>/dev/null | head -n 1 | awk -F= '{print $2}')
        start_img=$(echo "$DATA_RANGE" | awk '{print $1}')
        end_img=$(echo "$DATA_RANGE" | awk '{print $2}')
        if [[ -n "$start_img" && -n "$end_img" ]]; then

            NUM_IMAGES=$((end_img - start_img + 1))
        fi
        SPACEGROUP=$(grep -E "^SPACE_GROUP_NUMBER=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
        UNITCELL=$(grep -E "^UNIT_CELL_CONSTANTS=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | sed 's/^[ \t]*//')
        NAME_FRAMES=$(grep -E "^NAME_TEMPLATE_OF_DATA_FRAMES=" "$xdsinp_file" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    fi

    if [ -n "$NAME_FRAMES" ]; then
        img_dir=$(dirname "$NAME_FRAMES")
        [[ "$img_dir" = /* ]] && resolved_img_dir="$img_dir" || resolved_img_dir="$folder/$img_dir"
        if [ -d "$resolved_img_dir" ]; then
            IMAGES_PATH=$(realpath "$resolved_img_dir" 2>/dev/null)
        fi
    fi

    correct_file="$folder/$CORRECT_PATTERN"
    if [ -f "$correct_file" ]; then
        sg_match=$(grep "SPACE_GROUP_NUMBER=" "$correct_file" 2>/dev/null | tail -n 1 | awk -F= '{print $2}' | tr -d ' ')
        [ -n "$sg_match" ] && SPACEGROUP="$sg_match"

        uc_match=$(grep "UNIT_CELL_CONSTANTS=" "$correct_file" 2>/dev/null | tail -n 1 | awk -F= '{print $2}' | sed 's/^[ \t]*//')
        [ -n "$uc_match" ] && UNITCELL="$uc_match"

        isa_match=$(awk '/^[ \t]*a[ \t]*b[ \t]*ISa/{getline; print $3}' "$correct_file" 2>/dev/null | tail -n 1)
        [ -n "$isa_match" ] && ISA="$isa_match"
    fi

    echo "  Images       : $NUM_IMAGES"
    echo "  Space Group  : ${SPACEGROUP:-N/A}"
    echo "  Unit Cell    : ${UNITCELL:-N/A}"
    echo "  ISa          : ${ISA:-N/A}"
    echo "  Images path  : ${IMAGES_PATH:-N/A}"

    idxref_file="$folder/$IDXREF_PATTERN"
    percent_indexed=100
    subtree_ratio=0
    if [ -f "$idxref_file" ]; then
        if grep -q "$IDXREF_ERROR" "$idxref_file" 2>/dev/null; then
            echo "  [!] IDXREF ERROR: $idxref_file"
        else
          indexed_info=$(grep "SPOTS INDEXED" "$idxref_file" 2>/dev/null | tail -n 1)
          if [ -n "$indexed_info" ]; then
              total_spots=$(echo "$indexed_info" | awk '{print $4}')
              indexed_spots=$(echo "$indexed_info" | awk '{print $1}')
              if [[ "$total_spots" =~ ^[0-9]+$ ]] && [ "$total_spots" -gt 0 ]; then
                  percent_indexed=$(( 100 * indexed_spots / total_spots ))
                  INDEXING_WARNING="$indexed_spots of $total_spots ($percent_indexed% spots indexed)"
                  echo "  Indexing     : $INDEXING_WARNING"
              fi
          fi

          num_subtrees_line=$(grep "NUMBER OF SUBTREES" "$idxref_file" 2>/dev/null | tail -n 1)
          if [ -n "$num_subtrees_line" ]; then
              NUM_SUBTREES=$(echo "$num_subtrees_line" | awk '{print $NF}')
              if [[ "$NUM_SUBTREES" =~ ^[0-9]+$ ]] && [ "$NUM_SUBTREES" -gt 1 ]; then
                  read sub1 sub2 < <(awk '/SUBTREE[ \t]+POPULATION/{
                      while(getline > 0) {
                          if ($1 == "1") s1=$2;
                          if ($1 == "2") s2=$2;
                          if ($1 == "3" || $0 ~ /NUMBER OF ACCEPTED/) break;
                      }
                      print s1, s2;
                      exit;
                  }' "$idxref_file")
                  if [[ -n "$sub1" && -n "$sub2" && "$sub1" -gt 0 ]]; then
                      subtree_ratio=$(( 100 * sub2 / sub1 ))
                      # I also fixed a minor typo here: added the missing '$' to subtree_ratio
                      SUBTREE_WARNING="Sub2 is $subtree_ratio% size of Sub1: $sub2 spots)"
                      echo "  Subtree      : $SUBTREE_WARNING"

                  fi
              fi
          fi
        fi
    fi
done
echo "--------------------------------------------------------"
echo "Search complete."
: '
          if [ "$RERUN_XDS" -eq 1 ] && [ -f "$folder/XDS.INP" ] && ([ "$percent_indexed" -lt 80 ] || [ "$subtree_ratio" -gt 5 ]); then
              TEMP_DIR="$folder/temp_lattice2"
              mkdir -p "$TEMP_DIR"
              sed "s/^[[:space:]]*JOB[[:space:]]*=.*/JOB= IDXREF/" "$folder/XDS.INP" > "$TEMP_DIR/XDS.INP"
              awk "NF>=7 && $5==0 && $6==0 && $7==0 {print $0}" "$folder/SPOT.XDS" > "$TEMP_DIR/SPOT.XDS" 2>/dev/null
              (
                  cd "$TEMP_DIR" || exit
                  if command -v xds_par >/dev/null 2>&1; then
                      xds_par >/dev/null 2>&1
                  elif command -v xds >/dev/null 2>&1; then
                      xds >/dev/null 2>&1
                  fi
              )
              lat2_idxref="$TEMP_DIR/IDXREF.LP"
              if [ -f "$lat2_idxref" ]; then
                  lat2_indexed=$(grep "SPOTS INDEXED" "$lat2_idxref" 2>/dev/null | tail -n 1)
                  if [ -n "$lat2_indexed" ]; then

                      lat2_total_spots=$(echo "$lat2_indexed" | awk "{print $4}")
                      lat2_indexed_spots=$(echo "$lat2_indexed" | awk "{print $1}")

                      if [[ "$lat2_total_spots" =~ ^[0-9]+$ ]] && [ "$lat2_total_spots" -gt 0 ]; then
                          lat2_pct=$(( 100 * lat2_indexed_spots/ lat2_total_spots ))

                          if [ "$lat2_pct" -gt 25 ]; then
                              echo "  [!] SECOND LATTICE FOUND: $lat2_indexed_spots of $lat2_total_spots ($lat2_pct% of remaining)"
                              lat2_uc=$(grep "UNIT CELL PARAMETERS" "$lat2_idxref" 2>/dev/null | tail -n 1 | awk "{print $4, $5, $6, $7, $8, $9}")
                              echo "      Lat2 Unit Cell : ${lat2_uc:-N/A}"
                          else
                              echo "      No coherent second lattice found."
                          fi
                      fi
                  fi
              fi
              rm -rf "$TEMP_DIR"
          fi
        fi
    fi

done
'