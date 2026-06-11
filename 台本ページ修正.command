#!/bin/bash
cd "$(dirname "$0")"
echo "============================================"
echo "  台本ページ修正ツール（おぼえりふ用）"
echo "============================================"
echo ""
echo "AIが作った台本Excelの「ページ」列を、"
echo "元のPDFを見ながら正しく振り直します。"
echo ""

# 必要なライブラリを用意（初回だけ少し時間がかかります）
echo "準備中（初回のみ時間がかかります）..."
python3 -c "import fitz, openpyxl" 2>/dev/null || pip3 install --quiet pymupdf openpyxl

echo ""
echo "① 台本の【PDF】をこのウィンドウにドラッグして、Enter を押してください:"
read -r PDF
PDF="${PDF%\'}"; PDF="${PDF#\'}"   # ドラッグ時の引用符を外す
PDF=$(echo "$PDF" | sed "s/\\\\ / /g")

echo ""
echo "② AIが作った【Excel(.xlsx)】をドラッグして、Enter を押してください:"
read -r XLSX
XLSX="${XLSX%\'}"; XLSX="${XLSX#\'}"
XLSX=$(echo "$XLSX" | sed "s/\\\\ / /g")

echo ""
if [ ! -f "$PDF" ]; then echo "⚠️ PDFが見つかりません: $PDF"; sleep 8; exit 1; fi
if [ ! -f "$XLSX" ]; then echo "⚠️ Excelが見つかりません: $XLSX"; sleep 8; exit 1; fi

python3 tools/fix_serifu_pages.py "$PDF" "$XLSX"

echo ""
echo "✅ 完了。できた『_ページ修正版.xlsx』を、おぼえりふで取り込んでください。"
echo "（このウィンドウは閉じてOK）"
echo ""
sleep 3
