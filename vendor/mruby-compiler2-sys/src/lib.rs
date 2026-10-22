use std::ptr::null_mut;

#[allow(nonstandard_style)]
#[allow(dead_code)]
mod bindings {
    use std::os::raw::{c_char, c_int, c_void};

    pub const MRC_DUMP_OK: u32 = 0;
    pub const MRC_DUMP_DEBUG_INFO: u8 = 1;

    #[repr(C)]
    pub struct mrc_ccontext {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct mrc_irep {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct FILE {
        _private: [u8; 0],
    }

    unsafe extern "C" {
        pub fn mrc_ccontext_new(mrb: *mut c_void) -> *mut mrc_ccontext;
        pub fn mrc_ccontext_free(c: *mut mrc_ccontext);
        pub fn mrc_ccontext_filename(c: *mut mrc_ccontext, s: *const c_char) -> *const c_char;
        pub fn mrc_ccontext_error_message(c: *mut mrc_ccontext) -> *const c_char;
        pub fn mrc_ccontext_error_line(c: *mut mrc_ccontext) -> u32;
        pub fn mrc_ccontext_error_column(c: *mut mrc_ccontext) -> u32;
        pub fn mrc_load_string_cxt(
            c: *mut mrc_ccontext,
            source: *mut *const u8,
            length: usize,
        ) -> *mut mrc_irep;
        pub fn mrc_dump_irep(
            c: *mut mrc_ccontext,
            irep: *const mrc_irep,
            flags: u8,
            bin: *mut *mut u8,
            bin_size: *mut usize,
        ) -> c_int;
        pub fn mrc_irep_free(c: *mut mrc_ccontext, irep: *mut mrc_irep);
        pub fn mrc_codedump_all(c: *mut mrc_ccontext, irep: *mut mrc_irep);
        pub fn mrc_dump_irep_cfunc(
            c: *mut mrc_ccontext,
            irep: *const mrc_irep,
            flags: u8,
            fp: *mut FILE,
            initname: *const c_char,
        ) -> c_int;
    }
}

use bindings::{
    MRC_DUMP_DEBUG_INFO, MRC_DUMP_OK, mrc_ccontext, mrc_ccontext_error_column,
    mrc_ccontext_error_line, mrc_ccontext_error_message, mrc_ccontext_filename,
    mrc_ccontext_free, mrc_ccontext_new, mrc_codedump_all, mrc_dump_irep, mrc_irep,
    mrc_irep_free, mrc_load_string_cxt,
};

#[derive(Debug)]
pub struct MRubyCompiler2Error {
    details: String,
}

impl MRubyCompiler2Error {
    fn new(msg: &str) -> MRubyCompiler2Error {
        MRubyCompiler2Error {
            details: msg.to_string(),
        }
    }
}

impl std::fmt::Display for MRubyCompiler2Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.details)
    }
}

impl std::error::Error for MRubyCompiler2Error {}

pub struct MRubyCompiler2Context {
    c: *mut mrc_ccontext,
    filename: Option<String>,
}

impl MRubyCompiler2Context {
    /// Creates a new MRubyCompiler2Context
    pub unsafe fn new() -> Self {
        unsafe {
            let ccontext = mrc_ccontext_new(null_mut());
            MRubyCompiler2Context {
                c: ccontext,
                filename: None,
            }
        }
    }

    /// Sets the source filename for debug information and error reporting
    pub fn set_filename(&mut self, filename: &str) {
        self.filename = Some(filename.to_string());
        if let Ok(c_fn) = std::ffi::CString::new(filename) {
            unsafe {
                mrc_ccontext_filename(self.c, c_fn.as_ptr());
            }
        }
    }

    /// Compiles the given mruby code into mruby bytecode binary
    /// Returns the bytecode as a `Vec<u8>`
    pub unsafe fn compile(&mut self, code: &str) -> Result<Vec<u8>, MRubyCompiler2Error> {
        unsafe {
            let c_code = std::ffi::CString::new(code)
                .map_err(|_| MRubyCompiler2Error::new("Code includes null bytes"))?;
            let mut ptr = c_code.as_ptr() as *const u8;
            let irep =
                mrc_load_string_cxt(self.c, &mut ptr as *mut *const u8, c_code.as_bytes().len());

            if irep.is_null() {
                let err_msg_ptr = mrc_ccontext_error_message(self.c);
                let line = mrc_ccontext_error_line(self.c);
                let col = mrc_ccontext_error_column(self.c);
                let fn_str = self.filename.as_deref().unwrap_or("(script)");
                if !err_msg_ptr.is_null() {
                    let c_str = std::ffi::CStr::from_ptr(err_msg_ptr);
                    let msg = c_str.to_string_lossy();
                    return Err(MRubyCompiler2Error::new(&format!(
                        "{}:{}:{}: {}",
                        fn_str, line, col, msg
                    )));
                }
                return Err(MRubyCompiler2Error::new("Failed to compile code"));
            }

            let bin: &'static mut [u8] = Vec::with_capacity(code.len() * 2).leak();
            let bin_ptr = bin.as_mut_ptr();
            let mut bin_size: usize = 0;

            let result = mrc_dump_irep(
                self.c,
                irep as *mut mrc_irep,
                MRC_DUMP_DEBUG_INFO,
                &bin_ptr as *const *mut u8 as *mut *mut u8,
                &mut bin_size as *mut usize,
            );
            mrc_irep_free(self.c, irep as *mut mrc_irep);
            if result as u32 != MRC_DUMP_OK {
                return Err(MRubyCompiler2Error::new("Failed to dump irep binary"));
            }

            let newvec = Vec::from_raw_parts(bin_ptr, bin_size, bin_size);
            Ok(newvec)
        }
    }

    /// Dumps the compiled bytecode of the given mruby code to stdout
    #[cfg(feature = "std")]
    pub unsafe fn dump_bytecode(&mut self, code: &str) -> Result<(), MRubyCompiler2Error> {
        unsafe {
            let c_code = std::ffi::CString::new(code)
                .map_err(|_| MRubyCompiler2Error::new("Code includes null bytes"))?;
            let mut ptr = c_code.as_ptr() as *const u8;
            let irep =
                mrc_load_string_cxt(self.c, &mut ptr as *mut *const u8, c_code.as_bytes().len());

            if irep.is_null() {
                return Err(MRubyCompiler2Error::new("Failed to compile code"));
            }

            mrc_codedump_all(self.c, irep as *mut mrc_irep);
            mrc_irep_free(self.c, irep as *mut mrc_irep);
            Ok(())
        }
    }

    /// Compiles the given mruby code and writes the bytecode to the specified file path
    #[cfg(feature = "std")]
    pub unsafe fn compile_to_file(
        &mut self,
        code: &str,
        path: &std::path::Path,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let bin = unsafe { self.compile(code) }?;
        let mut out = std::fs::File::create(path)?;
        std::io::Write::write_all(&mut out, &bin)?;
        Ok(())
    }
}

impl Drop for MRubyCompiler2Context {
    fn drop(&mut self) {
        unsafe {
            mrc_ccontext_free(self.c);
        }
    }
}
