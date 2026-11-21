//! Drops GPUI's window doesn't take: it registers only for file names, but
//! the screenshot thumbnail (and Photos, Safari and other apps) drag a file
//! promise, the file written only once it's dropped, and Preview can drag a
//! bare picture. As Gannin's `ScreenshotDropTarget`, this takes those too,
//! for New Issue's images.
//!
//! At runtime it adds the promise and picture types to each GPUI window's
//! drag types and wraps the window class's drag methods. A drag of file
//! names goes to GPUI as before. A promise or picture, while New Issue
//! shows (`set_accepting`), is taken here: promised files are written to a
//! folder under the temporary directory and a picture saved there, and the
//! form picks the paths up with `take`. Anything else is left to GPUI.

use objc2::runtime::{AnyClass, AnyObject, Bool, Imp, Sel};
use objc2::{class, msg_send, sel};
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// NSDragOperationCopy.
const COPY: usize = 1;
const FILE_NAMES: &str = "NSFilenamesPboardType";
const PICTURES: [&str; 2] = ["public.png", "public.tiff"];

/// GPUI's own drag methods, called for drags this doesn't take.
struct Originals {
    entered: Imp,
    updated: Imp,
    perform: Imp,
}

static ORIGINALS: OnceLock<Option<Originals>> = OnceLock::new();
/// New Issue shows, so a promise or picture is wanted.
static ACCEPTING: AtomicBool = AtomicBool::new(false);
/// The drag under way is one this took at its start.
static OURS: AtomicBool = AtomicBool::new(false);
static DROPPED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

type DragFn = unsafe extern "C-unwind" fn(*mut AnyObject, Sel, *mut AnyObject) -> usize;
type PerformFn = unsafe extern "C-unwind" fn(*mut AnyObject, Sel, *mut AnyObject) -> Bool;

fn ns_string(text: &str) -> *mut AnyObject {
    let c = CString::new(text).unwrap_or_default();
    unsafe { msg_send![class!(NSString), stringWithUTF8String: c.as_ptr()] }
}

fn rust_string(ns: *mut AnyObject) -> Option<String> {
    if ns.is_null() {
        return None;
    }
    let utf8: *const std::ffi::c_char = unsafe { msg_send![ns, UTF8String] };
    (!utf8.is_null()).then(|| unsafe { std::ffi::CStr::from_ptr(utf8) }.to_string_lossy().into_owned())
}

fn ns_array(items: &[*mut AnyObject]) -> *mut AnyObject {
    unsafe { msg_send![class!(NSArray), arrayWithObjects: items.as_ptr(), count: items.len()] }
}

fn promise_class() -> *mut AnyObject {
    AnyClass::get(c"NSFilePromiseReceiver").map_or(std::ptr::null_mut(), |c| c as *const AnyClass as *mut AnyObject)
}

/// Wraps the GPUI window class's drag methods, once. Its class exists once
/// the first window is open.
pub fn install() {
    ORIGINALS.get_or_init(|| unsafe {
        let class = AnyClass::get(c"GPUIWindow")? as *const AnyClass as *mut AnyClass;
        let types = c"Q@:@".as_ptr();
        let entered: DragFn = dragging_entered;
        let updated: DragFn = dragging_updated;
        let perform: PerformFn = perform_drag;
        let entered = objc2::ffi::class_replaceMethod(class, sel!(draggingEntered:), std::mem::transmute::<DragFn, Imp>(entered), types)?;
        let updated = objc2::ffi::class_replaceMethod(class, sel!(draggingUpdated:), std::mem::transmute::<DragFn, Imp>(updated), types)?;
        let perform = objc2::ffi::class_replaceMethod(class, sel!(performDragOperation:), std::mem::transmute::<PerformFn, Imp>(perform), c"c@:@".as_ptr())?;
        Some(Originals { entered, updated, perform })
    });
    register_windows();
}

/// Adds the promise and picture types to every GPUI window's drag types,
/// keeping file names (registering replaces the set).
fn register_windows() {
    unsafe {
        let mut types: Vec<*mut AnyObject> = vec![ns_string(FILE_NAMES)];
        types.extend(PICTURES.iter().map(|t| ns_string(t)));
        let class = promise_class();
        if !class.is_null() {
            let readable: *mut AnyObject = msg_send![class, readableDraggedTypes];
            if !readable.is_null() {
                let count: usize = msg_send![readable, count];
                for i in 0..count {
                    types.push(msg_send![readable, objectAtIndex: i]);
                }
            }
        }
        let types = ns_array(&types);
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let windows: *mut AnyObject = msg_send![app, windows];
        let count: usize = msg_send![windows, count];
        let gpui = AnyClass::get(c"GPUIWindow");
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            let is_gpui: Bool = msg_send![window, isKindOfClass: gpui.map_or(std::ptr::null(), |c| c as *const AnyClass)];
            if is_gpui.as_bool() {
                let () = msg_send![window, registerForDraggedTypes: types];
            }
        }
    }
}

pub fn set_accepting(on: bool) {
    ACCEPTING.store(on, Ordering::Relaxed);
}

/// Files dropped since the last call.
pub fn take() -> Vec<PathBuf> {
    DROPPED.lock().map(|mut d| std::mem::take(&mut *d)).unwrap_or_default()
}

/// Whether a drag is a promise or a picture with no file names, which GPUI
/// would refuse.
unsafe fn is_ours(info: *mut AnyObject) -> bool {
    unsafe {
        if !ACCEPTING.load(Ordering::Relaxed) {
            return false;
        }
        let board: *mut AnyObject = msg_send![info, draggingPasteboard];
        if board.is_null() {
            return false;
        }
        let names: *mut AnyObject = msg_send![board, propertyListForType: ns_string(FILE_NAMES)];
        if !names.is_null() {
            return false;
        }
        let class = promise_class();
        if !class.is_null() {
            let promised: Bool = msg_send![board, canReadObjectForClasses: ns_array(&[class]), options: std::ptr::null_mut::<AnyObject>()];
            if promised.as_bool() {
                return true;
            }
        }
        let pictures: Vec<*mut AnyObject> = PICTURES.iter().map(|t| ns_string(t)).collect();
        let found: *mut AnyObject = msg_send![board, availableTypeFromArray: ns_array(&pictures)];
        !found.is_null()
    }
}

unsafe extern "C-unwind" fn dragging_entered(this: *mut AnyObject, cmd: Sel, info: *mut AnyObject) -> usize {
    unsafe {
        let ours = is_ours(info);
        OURS.store(ours, Ordering::Relaxed);
        if ours {
            return COPY;
        }
        match ORIGINALS.get().and_then(|o| o.as_ref()) {
            Some(o) => std::mem::transmute::<Imp, DragFn>(o.entered)(this, cmd, info),
            None => 0,
        }
    }
}

unsafe extern "C-unwind" fn dragging_updated(this: *mut AnyObject, cmd: Sel, info: *mut AnyObject) -> usize {
    unsafe {
        if OURS.load(Ordering::Relaxed) {
            return COPY;
        }
        match ORIGINALS.get().and_then(|o| o.as_ref()) {
            Some(o) => std::mem::transmute::<Imp, DragFn>(o.updated)(this, cmd, info),
            None => 0,
        }
    }
}

unsafe extern "C-unwind" fn perform_drag(this: *mut AnyObject, cmd: Sel, info: *mut AnyObject) -> Bool {
    unsafe {
        if !OURS.swap(false, Ordering::Relaxed) {
            return match ORIGINALS.get().and_then(|o| o.as_ref()) {
                Some(o) => std::mem::transmute::<Imp, PerformFn>(o.perform)(this, cmd, info),
                None => Bool::NO,
            };
        }
        Bool::new(receive(info))
    }
}

/// Where this drop's files go.
fn drop_folder() -> Option<PathBuf> {
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let folder = std::env::temp_dir().join("gannin-gpui-drops").join(stamp.to_string());
    std::fs::create_dir_all(&folder).ok().map(|_| folder)
}

unsafe fn receive(info: *mut AnyObject) -> bool {
    unsafe {
        let board: *mut AnyObject = msg_send![info, draggingPasteboard];
        let Some(folder) = drop_folder() else { return false };
        let class = promise_class();
        if !class.is_null() {
            let receivers: *mut AnyObject = msg_send![board, readObjectsForClasses: ns_array(&[class]), options: std::ptr::null_mut::<AnyObject>()];
            let count: usize = if receivers.is_null() { 0 } else { msg_send![receivers, count] };
            if count > 0 {
                let destination: *mut AnyObject = msg_send![class!(NSURL), fileURLWithPath: ns_string(&folder.to_string_lossy())];
                let options: *mut AnyObject = msg_send![class!(NSDictionary), dictionary];
                let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), new];
                let reader = block2::RcBlock::new(|url: *mut AnyObject, error: *mut AnyObject| {
                    if !url.is_null() && error.is_null() {
                        let path: *mut AnyObject = msg_send![url, path];
                        if let (Some(path), Ok(mut dropped)) = (rust_string(path), DROPPED.lock()) {
                            dropped.push(PathBuf::from(path));
                        }
                    }
                });
                for i in 0..count {
                    let receiver: *mut AnyObject = msg_send![receivers, objectAtIndex: i];
                    // Kept until its file is written.
                    let _: *mut AnyObject = msg_send![receiver, retain];
                    let () = msg_send![receiver, receivePromisedFilesAtDestination: destination, options: options, operationQueue: queue, reader: &*reader];
                }
                return true;
            }
        }
        for (kind, name) in [("public.png", "screenshot.png"), ("public.tiff", "screenshot.tiff")] {
            let data: *mut AnyObject = msg_send![board, dataForType: ns_string(kind)];
            if data.is_null() {
                continue;
            }
            let length: usize = msg_send![data, length];
            let bytes: *const u8 = msg_send![data, bytes];
            if bytes.is_null() || length == 0 {
                continue;
            }
            let path = folder.join(name);
            if std::fs::write(&path, std::slice::from_raw_parts(bytes, length)).is_ok() {
                if let Ok(mut dropped) = DROPPED.lock() {
                    dropped.push(path);
                }
                return true;
            }
        }
        false
    }
}
