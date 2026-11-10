#!/usr/bin/env python3
"""Validate localized Swift messages and the English/Korean catalog, without dependencies."""
from pathlib import Path
import collections
import json
import re

def string(s,i):
 start=i;i+=1;key='';n=0
 while i<len(s):
  if s[i]=='"':return i+1,key
  if s.startswith('\\(',i):
   depth=1;j=i+2
   while depth:
    if s[j]=='"':j,_=string(s,j);continue
    if s[j]=='(':depth+=1
    if s[j]==')':depth-=1
    j+=1
   key+='{'+str(n)+'}';n+=1;i=j;continue
  if s[i]=='\\':
   key+={'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\'}.get(s[i+1],s[i:i+2]);i+=2;continue
  key+=s[i];i+=1
 raise ValueError(start)
def tokens(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   j=s.find('\n',i);i=len(s) if j<0 else j;continue
  if s.startswith('/*',i):
   j=s.find('*/',i+2);i=len(s) if j<0 else j+2;continue
  raw=re.match(r'(#+)?"""',s[i:])
  if raw:
   end='"""'+(raw.group(1) or '');j=s.find(end,i+len(raw.group()));i=j+len(end);continue
  if s[i]=='"':
   end,key=string(s,i);yield i,end,key;i=end
  else:i+=1

root = Path(__file__).resolve().parent.parent
catalog = json.loads((root / "Sources/WorkspaceCore/Resources/Localizations.json").read_text())
failures = []
for key, values in catalog.items():
    if set(values) != {"en", "ko"}:
        failures.append(f"Missing language: {key}")
    for language, text in values.items():
        if not text or collections.Counter(re.findall(r"\{\d+\}", key)) != collections.Counter(re.findall(r"\{\d+\}", text)):
            failures.append(f"Invalid placeholders: {language}: {key}")
        if re.search("[\u3040-\u30ff]", text):
            failures.append(f"Untranslated Japanese: {language}: {key}")
count = 0
for path in (root / "Sources").rglob("*.swift"):
    if "Checks" in path.name:
        continue
    source = path.read_text()
    for start, end, key in tokens(source):
        if re.search(r"\bL\(\s*$", source[max(0,start-20):start]):
            count += 1
            if key not in catalog:
                failures.append(f"Missing key: {path.name}:{source.count(chr(10),0,start)+1}: {key}")
if failures:
    raise SystemExit("\n".join(failures))
print(f"PASS {len(catalog)} bilingual translations; {count} localized Swift call sites; all placeholders preserved")
