import re
with open('cart_loader.v') as f:
    loader = f.read()
with open('top.v') as f:
    top = f.read()

outputs = re.findall(r'output\s+reg\s+(?:\[[^\]]*\]\s*)?([a-zA-Z0-9_]+)', loader)
outputs += re.findall(r'output\s+wire\s+(?:\[[^\]]*\]\s*)?([a-zA-Z0-9_]+)', loader)

for out in outputs:
    if re.search(r'reg\s+(?:\[[^\]]*\])?\s*' + out, top):
        print(f"ERROR: {out} is declared as reg in top.v!")
