pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("d3d11.h");
    @cInclude("d3dcompiler.h");
    @cInclude("dxgi.h");
});

// Manual definitions for untranslatable macros
pub const IDC_ARROW = @as([*c]const u8, @ptrFromInt(32512));
pub const CW_USEDEFAULT = @as(c_int, @bitCast(@as(c_uint, 0x80000000)));
pub const HWND_TOP: ?*c.struct_HWND__ = null;
pub const MONITOR_DEFAULTTOPRIMARY: c.DWORD = 0x00000001;

pub const IID_IDXGIDevice = c.GUID{
    .Data1 = 0x77db970f,
    .Data2 = 0x6276,
    .Data3 = 0x48ba,
    .Data4 = .{ 0xba, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c },
};

pub const IID_IDXGIFactory = c.GUID{
    .Data1 = 0x770aae78,
    .Data2 = 0xf26f,
    .Data3 = 0x4dba,
    .Data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 },
};

pub const IID_ID3D11Texture2D = c.GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

pub const IID_IDXGISurface1 = c.GUID{
    .Data1 = 0x4AE63092,
    .Data2 = 0x6327,
    .Data3 = 0x4c1b,
    .Data4 = .{ 0x80, 0xAE, 0xBF, 0xE1, 0x2E, 0xA3, 0x2B, 0x86 },
};