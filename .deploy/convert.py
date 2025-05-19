import re
import gzip
import subprocess
from pathlib import Path
import os
import sys
import xml.etree.ElementTree as ET
import tempfile
import subprocess
import shutil
from pathlib import Path
import re

OUTPUT_DIR = "./output"

class XoppUtils:
  def __init__(self, path: Path):
    self.path = path
    pass

  def _findBestAbsolute(self, file: Path) -> Path:
    targetParent = str(file.parent).split("/")

    def _compareLastNIsSame(a: list, b: list, n: int) -> bool:
      if n == 0: 
        return True

      return a[:-(n+1):-1] == b[:-(n+1):-1]
    
    def _fetchSameParentCount(e: Path) -> int:
      elementParent = str(e.parent).split("/")

      counts = min(len(elementParent), len(targetParent))

      for i in range(counts, 0, -1):
        if _compareLastNIsSame(elementParent, targetParent, i):
          return i
  
      return 0
    
    possibility: list[Path] = sorted(
        Path(".").rglob(f"{file.name}"),
        key=_fetchSameParentCount, 
        reverse=True
    )
                        
    return possibility[0]
  
  def fixBackground(self):
    with gzip.open(self.path.absolute(), 'rt', encoding='utf-8') as fin:
      content = fin.read()

    # Find PDF background string and change it to relativily path
    
    findResult = re.findall(r'filename="(.+?)/([^/]+\.pdf)"', content)

    # Return if background image is not found
    if not findResult:
      return
    
    ogFilePath = f"{findResult[0][0]}/{findResult[0][1]}"

    newPath = self._findBestAbsolute(Path(ogFilePath))
    
    if not newPath:
      return
    print(f"RESULT IS: {newPath.absolute()}")
    
    content = re.sub(r'filename="(.+?)/([^/]+\.pdf)"', f'filename="{newPath.absolute()}"', content)
    
    # Save fixed xopp file
    with gzip.open(self.path.absolute(), 'wt', encoding='utf-8') as fout:
      fout.write(content)

  def convertToPdf(self) -> subprocess.CompletedProcess:
    relative_path = self.path.relative_to(Path("."))
    output_folder = OUTPUT_DIR / relative_path.parent
    output_pdf = output_folder / f"{self.path.name}.pdf"

    # 建立對應的子資料夾
    output_folder.mkdir(parents=True, exist_ok=True)

    # 執行 Xournal++ 轉換
    return subprocess.run(["xournalpp", "-p", str(output_pdf), str(self.path.absolute())], check=True)

  @staticmethod
  def fetchXoppFiles(root_dir: Path = Path(".")) -> list['XoppUtils']:
    result = [ XoppUtils(p) for p in Path(root_dir).rglob("*.xopp") if not p.name.endswith(".autosave.xopp")]
    return result

def main() -> None:
    files = XoppUtils.fetchXoppFiles()

    count = len(files)
    print(f"Found {count} valid files in this directory.")

    for index, item in enumerate(files, 1):
      print(f"[{index}/{count}]", end=f" Processing \"{item.path.name}\" ")

      print(f"fix pdf...", end=" ")
      item.fixBackground()
      print("Done.")

      try:
          item.convertToPdf()
      except subprocess.CalledProcessError as e:
          print(f"Error converting {item.path.name} \n{e.stderr}")

if __name__ == "__main__":
    main()