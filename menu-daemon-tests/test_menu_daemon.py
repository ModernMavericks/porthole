import importlib.util, os, sys
_path = os.path.join(os.path.dirname(__file__), "..", "porthole-menu-daemon.py")
_spec = importlib.util.spec_from_file_location("menudaemon", _path)
md = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(md)


class FakeView:
    # Duck-typed node view the pure core consumes. `key` is a stable identity.
    def __init__(self, key, role, name="", sensitive=True, checked=None,
                 keybinding=None, children=None):
        self.key, self.role, self.name = key, role, name
        self.sensitive, self.checked = sensitive, checked
        self.keybinding, self.children = keybinding, list(children or [])


def test_parse_keybinding_primary_letter():
    assert md.parse_keybinding("mnemonic;<Alt>f;<Primary>n") == {"key": "n", "mods": ["cmd"]}

def test_parse_keybinding_primary_shift():
    assert md.parse_keybinding(";;<Primary><Shift>s") == {"key": "s", "mods": ["cmd", "shift"]}

def test_parse_keybinding_bare_function_key():
    assert md.parse_keybinding("F11") == {"key": "f11", "mods": []}

def test_parse_keybinding_blank_is_none():
    assert md.parse_keybinding("") is None
    assert md.parse_keybinding("mnemonic;;") is None

def test_build_node_item_strips_trailing_space_and_reads_enabled():
    v = FakeView("k1", "menu item", "Reload ", sensitive=False)
    idg = md.IdGen()
    n = md.build_node(v, idg)
    assert n["role"] == "item" and n["label"] == "Reload" and n["enabled"] is False

def test_build_node_submenu_and_separator_and_accel():
    save = FakeView("k2", "menu item", "Save", keybinding=";;<Primary>s")
    sep = FakeView("k3", "separator")
    filem = FakeView("k4", "menu", "File", children=[save, sep])
    idg = md.IdGen()
    n = md.build_node(filem, idg)
    assert n["role"] == "submenu" and n["label"] == "File"
    assert [c["role"] for c in n["children"]] == ["item", "separator"]
    assert n["children"][0]["accel"] == {"key": "s", "mods": ["cmd"]}

def test_build_node_checkbox_carries_checked():
    v = FakeView("k5", "check menu item", "Word Wrap", checked=True)
    n = md.build_node(v, md.IdGen())
    assert n["role"] == "checkbox" and n["checked"] is True

def test_ids_are_stable_per_view_and_reversible():
    a = FakeView("ka", "menu item", "A")
    idg = md.IdGen()
    i1 = idg.id_for(a); i2 = idg.id_for(a)
    assert i1 == i2 and idg.view_for_id(i1) is a

def test_snapshot_and_delta_and_encode():
    a = FakeView("ka", "menu item", "A", sensitive=True)
    root = FakeView("kr", "menu bar", "", children=[FakeView("km", "menu", "M", children=[a])])
    idg = md.IdGen()
    snap = md.build_snapshot([root_child for root_child in root.children], idg)
    line = md.encode_line({"t": "menu", "root": snap})
    assert line.endswith(b"\n") and b'"t": "menu"' in line
    aid = idg.id_for(a)
    d = md.delta_for(aid, enabled=False)
    assert d == {"id": aid, "enabled": False}


def test_build_node_empty_menu_is_lazy_submenu():
    # A "menu" with no materialized children -> lazy submenu (children load on open).
    v = FakeView("kz", "menu", "File", children=[])
    n = md.build_node(v, md.IdGen())
    assert n["role"] == "submenu" and n.get("lazy") is True and "children" not in n
