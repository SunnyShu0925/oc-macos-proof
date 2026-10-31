import sys
import pathlib

src = pathlib.Path(sys.argv[1])
text = src.read_text()

head1 = '''        // `current` is nil when the session inherits the agent default; show no
        // item as selected instead of manufacturing an "off" check.
        let selected = levels.contains(current ?? "") ? current : nil'''
base1 = '''        let selected = levels.contains(current ?? "") ? current ?? "off" : "off"'''

head2 = '''        // Mirror buildPreferenceMenu: a nil `current` (inheriting the agent
        // default) leaves every item unchecked.
        let selected = current'''
base2 = '''        let selected = menu.items.contains {
            ($0.representedObject as? [String: String])?["value"] == current
        } ? current : "off"'''

if head1 not in text or head2 not in text:
    sys.exit("base mode: head hunks not found in " + str(src))
text = text.replace(head1, base1).replace(head2, base2)
src.write_text(text)
print("BASE mode: restored the Off fallback")
