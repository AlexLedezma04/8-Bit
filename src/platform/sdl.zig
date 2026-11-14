//! The only place SDL's C API is imported. Other platform files use this.
pub const c = @import("sdl");
