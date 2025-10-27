#!/bin/bash

# 當任何指令失敗時，立即終止腳本
set -e
# 確保在管道 (pipe) 中，任何一個指令失敗都會被視為整個管道的失敗
set -o pipefail

# --- 全域設定 ---
# 轉換後的 PDF 檔案將會被放置在此資料夾下，並維持原有的相對路徑結構
OUTPUT_DIR="./output"

# --- 函式定義 ---

# 函式：計算兩個路徑有多少層共同的父目錄
# 用法：_get_common_parent_count "/path/to/a" "/path/to/b"
# 輸出：一個數字 (e.g., 2)
_get_common_parent_count() {
  local path1="$1"
  local path2="$2"
  
  # 將路徑字串轉換為陣列，以 '/' 作為分隔符
  # ${path//\// } 會將所有 '/' 替換為空格
  IFS=' ' read -r -a parents1 <<< "${path1//\// }"
  IFS=' ' read -r -a parents2 <<< "${path2//\// }"

  local count=0
  local len1=${#parents1[@]}
  local len2=${#parents2[@]}
  local min_len=$(( len1 < len2 ? len1 : len2 ))

  # 從後向前比較兩個陣列的元素
  for (( i=1; i<=min_len; i++ )); do
    if [[ "${parents1[len1-i]}" == "${parents2[len2-i]}" ]]; then
      ((count++))
    else
      break
    fi
  done

  echo "$count"
}

# 函式：在當前目錄下遞迴尋找一個檔案，並找出與原始路徑最匹配的一個
# 這個函式模擬了 Python 版本中 _findBestAbsolute 的核心邏輯
# 用法：find_best_absolute_path "original/path/to/file.pdf"
# 輸出：找到的最佳路徑 (e.g., ./new/path/to/file.pdf)
find_best_absolute_path() {
  local original_path="$1"
  local filename
  filename=$(basename "$original_path")

  local best_match=""
  local max_score=-1

  # 使用 find 找出所有可能的候選檔案
  # -print0 和 read -d $'\0' 確保能正確處理包含空格或特殊字元的檔名
  while IFS= read -r -d $'\0' candidate; do
    # 取得候選路徑的父目錄
    local candidate_parent
    candidate_parent=$(dirname "$candidate")
    # 取得原始路徑的父目錄
    local original_parent
    original_parent=$(dirname "$original_path")

    # 計算它們父目錄的相似度分數
    local score
    score=$(_get_common_parent_count "$candidate_parent" "$original_parent")

    if (( score > max_score )); then
        max_score=$score
        best_match=$candidate
    fi
  done < <(find . -type f -name "$filename" -print0)

  if [[ -n "$best_match" ]]; then
    # 使用 realpath 取得絕對路徑
    realpath "$best_match"
  else
    echo "" # 如果沒找到，回傳空字串
  fi
}

# 函式：修復單一 .xopp 檔案中 PDF 背景的絕對路徑問題
# 用法：fix_background "path/to/your/file.xopp"
fix_background() {
  local xopp_file="$1"
  
  # .xopp 是 gzip 壓縮的 xml，所以先解壓縮到變數中
  # gunzip -c 會將解壓後的內容輸出到 stdout
  local content
  content=$(gunzip -c "$xopp_file")

  # 使用 grep 和 Perl-compatible regex (-P) 找出 PDF 背景路徑
  # -o 只顯示匹配的部分, \K 會捨棄掉 "filename=" 這部分
  local original_pdf_path
  original_pdf_path=$(echo "$content" | grep -oP 'filename="\K[^"]+\.pdf' || true)

  # 如果沒找到 PDF 背景，或路徑為空，就直接返回
  if [[ -z "$original_pdf_path" ]]; then
    echo "No PDF background found." # 可選的除錯訊息
    return
  fi
  
  # 尋找最佳的本地檔案路徑
  local new_abs_path
  new_abs_path=$(find_best_absolute_path "$original_pdf_path")

  # 如果沒找到對應的檔案，也直接返回
  if [[ -z "$new_abs_path" ]]; then
    # echo "Could not find a local match for $original_pdf_path." # 可選的除錯訊息
    return
  fi

  # 使用 sed 進行替換。注意：
  # 1. 使用 | 作為分隔符，避免與路徑中的 / 衝突
  # 2. $new_abs_path 中的特殊字元需要被轉義，sed 的第三個參數可以處理這點
  local new_content
  new_content=$(echo "$content" | sed "s|filename=\"[^\"]*/[^\"]*\.pdf\"|filename=\"$new_abs_path\"|")

  echo "Done. (Fixed path to '$new_abs_path')"

  # 將修改後的內容重新壓縮並寫回原檔案
  # 使用暫存檔案確保寫入過程的原子性和安全性
  local temp_file
  temp_file=$(mktemp)
  echo "$new_content" | gzip > "$temp_file"
  mv "$temp_file" "$xopp_file"
}

# 函式：將單一 .xopp 檔案轉換為 PDF
# 用法：convert_to_pdf "path/to/your/file.xopp"
convert_to_pdf() {
  local xopp_file="$1"
  
  # 取得相對於當前目錄的路徑，用於建立輸出子目錄
  local relative_path
  relative_path=$(realpath --relative-to="." "$xopp_file")

  local output_folder="$OUTPUT_DIR/$(dirname "$relative_path")"
  local output_pdf="$output_folder/$(basename "$xopp_file").pdf"

  # 建立對應的子資料夾
  mkdir -p "$output_folder"

  # 執行 Xournal++ 轉換，並取得絕對路徑以避免問題
  local xopp_abs_path
  xopp_abs_path=$(realpath "$xopp_file")
  
  # 執行轉換指令，並檢查其是否成功
  local error_output
  # 嘗試執行指令，並將 stderr 捕捉到 error_output 變數中
  # >/dev/null 只丟棄 stdout，保留 stderr
  if ! error_output=$(xournalpp -p "$output_pdf" "$xopp_abs_path" 2>&1 >/dev/null); then
    echo "failed:" >&2
    # 將捕捉到的實際錯誤訊息印出來
    echo "    $error_output" >&2

    return
  fi

  printf "Done.\n"
}

# --- 主函式 ---
main() {
  # 找出所有 .xopp 檔案，並排除 .autosave.xopp 檔案
  # 使用 mapfile 將 find 的結果安全地讀入一個陣列
  mapfile -t files < <(find . -type f -name "*.xopp" ! -name "*.autosave.xopp" | sort)

  local count=${#files[@]}
  echo "Found $count valid files in this directory."

  if (( count == 0 )); then
    echo "No file needed to be convert, exiting..."
    exit 0
  fi

  local index=0
  for file in "${files[@]}"; do
    let index=index+1
    
    printf "[%3d/%3d] Processing \"%s\":\n" "$index" "$count" "$file"

    printf "  Fixing pdf... "
    fix_background "$file"
    
    # 轉換為 PDF 的部分可以取消註解來啟用
    printf "  Convert to pdf... "
    convert_to_pdf "$file"
  done
  
  echo "All tasks completed."
}

# --- 腳本執行入口 ---
main "$@"