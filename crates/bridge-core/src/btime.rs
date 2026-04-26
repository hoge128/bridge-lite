// bridge-lite btime preservation policy (mirrors imanage):
//   Bridge-lite must NEVER change the btime (st_birthtime) of any user file.
//   Wrap every in-place write to a user file with `preserve_btime`.
//
// Usage:
//   crate::btime::preserve_btime(&path, || { /* write op */ })?;
//
// On non-macOS platforms the wrapper is a no-op.

#[cfg(target_os = "macos")]
mod imp {
    use std::io;
    use std::path::Path;

    fn get_btime(path: &Path) -> io::Result<libc::timespec> {
        use std::os::macos::fs::MetadataExt;
        let meta = std::fs::metadata(path)?;
        Ok(libc::timespec {
            tv_sec:  meta.st_birthtime() as libc::time_t,
            tv_nsec: meta.st_birthtime_nsec() as libc::c_long,
        })
    }

    fn set_btime(path: &Path, ts: libc::timespec) -> io::Result<()> {
        use std::os::unix::ffi::OsStrExt;
        let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

        let mut al = libc::attrlist {
            bitmapcount: libc::ATTR_BIT_MAP_COUNT,
            reserved:    0,
            commonattr:  libc::ATTR_CMN_CRTIME,
            volattr:     0,
            dirattr:     0,
            fileattr:    0,
            forkattr:    0,
        };

        let mut buf = ts; // timespec is the exact buffer layout setattrlist expects
        let ret = unsafe {
            libc::setattrlist(
                c_path.as_ptr(),
                &mut al as *mut libc::attrlist as *mut libc::c_void,
                &mut buf as *mut libc::timespec as *mut libc::c_void,
                std::mem::size_of::<libc::timespec>(),
                0,
            )
        };

        if ret == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    /// Run `f`, then restore the btime of `path` to whatever it was before.
    /// If `path` does not yet exist (new file), btime is left as-is.
    /// Errors from btime restoration are silently ignored — the write result
    /// is what callers care about.
    pub fn preserve_btime<F, T>(path: &Path, f: F) -> io::Result<T>
    where
        F: FnOnce() -> io::Result<T>,
    {
        let saved = get_btime(path).ok();
        let result = f()?;
        if let Some(ts) = saved {
            let _ = set_btime(path, ts);
        }
        Ok(result)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::io;
    use std::path::Path;

    pub fn preserve_btime<F, T>(_path: &Path, f: F) -> io::Result<T>
    where
        F: FnOnce() -> io::Result<T>,
    {
        f()
    }
}

pub use imp::preserve_btime;
