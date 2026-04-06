import AppKit
import ObjectiveC.runtime

// ---------------------------------------------------------------------------
// Localization bootstrap for SPM debug builds.
//
// In a raw SPM binary, resources live in murmur_murmur.bundle (Bundle.module),
// while both SwiftUI and Foundation default to Bundle.main which has none.
//
// Strategy 1 – ObjC runtime override: inherit from Bundle.main's real class,
//   add localizedString override that delegates to Bundle.module, then swap
//   the ISA of the Bundle.main singleton.
//
// Strategy 2 – filesystem copy: copy each .lproj directory from Bundle.module
//   into Bundle.main's bundle directory so NSBundle finds them naturally.
//   (Idempotent: skipped if the destination already exists.)
// ---------------------------------------------------------------------------

private func bootstrapLocalization() {

    // ── Strategy 1: ObjC isa-swap ──────────────────────────────────────────
    let sel = #selector(Bundle.localizedString(forKey:value:table:))
    if let method = class_getInstanceMethod(Bundle.self, sel),
       let types  = method_getTypeEncoding(method) {

        let base = type(of: Bundle.main) as AnyClass
        if let cls = objc_allocateClassPair(base, "_MurmurMainBundle", 0) {
            let imp = imp_implementationWithBlock(
                { (_: AnyObject, key: String, val: String?, tbl: String?) -> String in
                    Bundle.module.localizedString(forKey: key, value: val, table: tbl)
                } as @convention(block) (AnyObject, String, String?, String?) -> String
            )
            class_addMethod(cls, sel, imp, types)
            objc_registerClassPair(cls)
            object_setClass(Bundle.main, cls)
        }
    }

    // ── Strategy 2: filesystem copy ────────────────────────────────────────
    let fm = FileManager.default
    // Bundle.module's resource root contains zh-hans.lproj, en.lproj, …
    // .lproj dirs live at the bundle root, not inside resourceURL (Resources/)
    guard let srcRoot = Bundle.module.resourceURL?.deletingLastPathComponent() else { return }
    let dstRoot = Bundle.main.bundleURL

    let items = (try? fm.contentsOfDirectory(at: srcRoot, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.pathExtension == "lproj" {
        let dst = dstRoot.appendingPathComponent(item.lastPathComponent)
        guard !fm.fileExists(atPath: dst.path) else { continue }
        try? fm.copyItem(at: item, to: dst)
    }
}

bootstrapLocalization()

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
