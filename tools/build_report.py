"""Génère docs/Rapport-PatchManagement.docx à partir de docs/RAPPORT.md (pandoc).
Usage : python tools/build_report.py   (nécessite pandoc, ou : pip install pypandoc_binary)"""
import pathlib, subprocess, shutil
root = pathlib.Path(__file__).resolve().parent.parent
docs = root / 'docs'
try:
    import pypandoc
    pandoc = pypandoc.get_pandoc_path()
except ImportError:
    pandoc = shutil.which('pandoc')
md = (docs / 'RAPPORT.md').read_text(encoding='utf-8')
md = md.replace('*[Capture 6 : rapport HTML]*',
    '![Exemple de rapport HTML généré (données fictives, à remplacer par la capture du laboratoire)](images/exemple-rapport-html.png){width=16cm}')
tmp = docs / '_rapport_build.md'
tmp.write_text(md, encoding='utf-8')
try:
    subprocess.run([pandoc, tmp.name, '-f', 'markdown', '-t', 'docx',
                    '-M', 'lang=fr-FR',
                    '-o', 'Rapport-PatchManagement.docx'], cwd=docs, check=True)
finally:
    tmp.unlink()
print('OK', docs / 'Rapport-PatchManagement.docx')
