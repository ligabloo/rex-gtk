//! Stands in for Ghostty's src/renderer.zig. Re-exports the parts of
//! Ghostty's renderer that rex-gtk uses, from the pinned source. Ghostty's
//! own renderer loop (generic.zig, Thread.zig, OpenGL.zig) is not used;
//! rex-gtk's src/render/renderer.zig takes its place.

pub const size = @import("renderer/size.zig");
pub const CellSize = size.CellSize;
pub const GridSize = size.GridSize;
pub const ScreenSize = size.ScreenSize;
pub const Padding = size.Padding;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;

pub const cursor = @import("renderer/cursor.zig");
pub const CursorStyle = cursor.Style;
pub const cursorStyle = cursor.style;

pub const cell = @import("renderer/cell.zig");
pub const row = @import("renderer/row.zig");

/// The OpenGL building blocks: pipelines, buffers, textures, render
/// targets and passes, and the shaders that draw the terminal.
pub const opengl = struct {
    pub const Device = @import("renderer/opengl/Device.zig");
    pub const Target = @import("renderer/opengl/Target.zig");
    pub const RenderPass = @import("renderer/opengl/RenderPass.zig");
    pub const Pipeline = @import("renderer/opengl/Pipeline.zig");
    pub const Sampler = @import("renderer/opengl/Sampler.zig");
    pub const Texture = @import("renderer/opengl/Texture.zig");
    pub const buffer = @import("renderer/opengl/buffer.zig");
    pub const shaders = @import("renderer/opengl/shaders.zig");
};

pub const Dmabuf = @import("renderer/Dmabuf.zig");

/// cell.zig reaches the shader types as `renderer.Renderer.API.shaders`.
pub const Renderer = struct {
    pub const API = struct {
        pub const shaders = opengl.shaders;
    };
};
