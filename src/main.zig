const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;

const compute_shader = @embedFile("mandelbrot.hlsl");

const WIDTH = 1280;
const HEIGHT = 720;

// Precomputed zoom constants: exp(±0.1) so zoom in/out cancel exactly
const ZOOM_IN: f64 = 0.904837418035959573164249059915; // exp(-0.1)
const ZOOM_OUT: f64 = 1.105170918075647624811707826490; // exp(0.1)

const ViewParams = extern struct {
    center_x: f32,
    center_y: f32,
    scale: f32,
    rotation: f32,
    width: u32,
    height: u32,
    max_iter: u32,
    padding: u32,
};

const State = struct {
    center_x: f64 = -0.5,
    center_y: f64 = 0.0,
    scale: f64 = 3.0,
    rotation: f64 = 0.0,
    show_info: bool = true,
    width: u32 = WIDTH,
    height: u32 = HEIGHT,
    is_fullscreen: bool = false,
    windowed_rect: c.RECT = undefined,
    windowed_style: c.DWORD = 0,
};

var state = State{};
var hwnd_global: c.HWND = null;
var device: ?*c.ID3D11Device = null;
var context: ?*c.ID3D11DeviceContext = null;
var swap_chain: ?*c.IDXGISwapChain = null;
var rtv: ?*c.ID3D11RenderTargetView = null;
var compute_shader_obj: ?*c.ID3D11ComputeShader = null;
var output_texture: ?*c.ID3D11Texture2D = null;
var output_uav: ?*c.ID3D11UnorderedAccessView = null;
var output_srv: ?*c.ID3D11ShaderResourceView = null;
var const_buffer: ?*c.ID3D11Buffer = null;
var vertex_shader: ?*c.ID3D11VertexShader = null;
var pixel_shader: ?*c.ID3D11PixelShader = null;
var sampler: ?*c.ID3D11SamplerState = null;

fn initD3D(hwnd: c.HWND) !void {
    var feature_level: c.D3D_FEATURE_LEVEL = undefined;
    const create_flags: c.UINT = 0;

    var hr = c.D3D11CreateDevice(
        null,
        c.D3D_DRIVER_TYPE_HARDWARE,
        null,
        create_flags,
        null,
        0,
        c.D3D11_SDK_VERSION,
        @ptrCast(&device),
        &feature_level,
        @ptrCast(&context),
    );
    if (hr < 0) return error.D3DInitFailed;

    var dxgi_device: ?*c.IDXGIDevice1 = null;
    hr = device.?.lpVtbl.*.QueryInterface.?(@ptrCast(device.?), &win32.IID_IDXGIDevice, @ptrCast(&dxgi_device));
    if (hr < 0) return error.QueryInterfaceFailed;
    defer _ = dxgi_device.?.lpVtbl.*.Release.?(@ptrCast(dxgi_device.?));

    var adapter: ?*c.IDXGIAdapter = null;
    hr = dxgi_device.?.lpVtbl.*.GetAdapter.?(dxgi_device.?, &adapter);
    if (hr < 0) return error.GetAdapterFailed;
    defer _ = adapter.?.lpVtbl.*.Release.?(@ptrCast(adapter.?));

    var factory: ?*c.IDXGIFactory1 = null;
    hr = adapter.?.lpVtbl.*.GetParent.?(@ptrCast(adapter.?), &win32.IID_IDXGIFactory, @ptrCast(&factory));
    if (hr < 0) return error.QueryInterfaceFailed;
    defer _ = factory.?.lpVtbl.*.Release.?(@ptrCast(factory.?));

    var swap_desc = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC);
    swap_desc.BufferCount = 1;
    swap_desc.BufferDesc.Width = WIDTH;
    swap_desc.BufferDesc.Height = HEIGHT;
    swap_desc.BufferDesc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM; // Use BGRA for GDI compatibility
    swap_desc.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.OutputWindow = hwnd;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.Windowed = c.TRUE;
    swap_desc.SwapEffect = c.DXGI_SWAP_EFFECT_DISCARD;
    swap_desc.Flags = c.DXGI_SWAP_CHAIN_FLAG_GDI_COMPATIBLE; // Enable GDI compatibility

    hr = factory.?.lpVtbl.*.CreateSwapChain.?(factory.?, @ptrCast(device.?), &swap_desc, @ptrCast(&swap_chain));
    if (hr < 0) return error.CreateSwapChainFailed;

    try createRenderTarget();
    try createComputeResources();
    try createDisplayShaders();
}

fn createRenderTarget() !void {
    var back_buffer: ?*c.ID3D11Texture2D = null;
    var hr = swap_chain.?.lpVtbl.*.GetBuffer.?(swap_chain.?, 0, &win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
    if (hr < 0) return error.GetBufferFailed;
    defer _ = back_buffer.?.lpVtbl.*.Release.?(@ptrCast(back_buffer.?));

    hr = device.?.lpVtbl.*.CreateRenderTargetView.?(device.?, @ptrCast(back_buffer.?), null, @ptrCast(&rtv));
    if (hr < 0) return error.CreateRTVFailed;
}

fn createComputeResources() !void {
    const shader_blob = try compileShader(compute_shader, "CSMain", "cs_5_0");
    defer _ = shader_blob.lpVtbl.*.Release.?(@ptrCast(shader_blob));

    const shader_data = shader_blob.lpVtbl.*.GetBufferPointer.?(shader_blob);
    const shader_size = shader_blob.lpVtbl.*.GetBufferSize.?(shader_blob);

    var hr = device.?.lpVtbl.*.CreateComputeShader.?(device.?, shader_data, shader_size, null, @ptrCast(&compute_shader_obj));
    if (hr < 0) return error.CreateComputeShaderFailed;

    var tex_desc = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
    tex_desc.Width = state.width;
    tex_desc.Height = state.height;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
    tex_desc.SampleDesc.Count = 1;
    tex_desc.Usage = c.D3D11_USAGE_DEFAULT;
    tex_desc.BindFlags = c.D3D11_BIND_UNORDERED_ACCESS | c.D3D11_BIND_SHADER_RESOURCE;

    hr = device.?.lpVtbl.*.CreateTexture2D.?(device.?, &tex_desc, null, @ptrCast(&output_texture));
    if (hr < 0) return error.CreateTextureFailed;

    hr = device.?.lpVtbl.*.CreateUnorderedAccessView.?(device.?, @ptrCast(output_texture.?), null, @ptrCast(&output_uav));
    if (hr < 0) return error.CreateUAVFailed;

    hr = device.?.lpVtbl.*.CreateShaderResourceView.?(device.?, @ptrCast(output_texture.?), null, @ptrCast(&output_srv));
    if (hr < 0) return error.CreateSRVFailed;

    var cb_desc = std.mem.zeroes(c.D3D11_BUFFER_DESC);
    cb_desc.ByteWidth = @sizeOf(ViewParams);
    cb_desc.Usage = c.D3D11_USAGE_DYNAMIC;
    cb_desc.BindFlags = c.D3D11_BIND_CONSTANT_BUFFER;
    cb_desc.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

    hr = device.?.lpVtbl.*.CreateBuffer.?(device.?, &cb_desc, null, @ptrCast(&const_buffer));
    if (hr < 0) return error.CreateBufferFailed;
}

fn createDisplayShaders() !void {
    const vs_code =
        \\struct VS_OUT { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
        \\VS_OUT main(uint id : SV_VertexID) {
        \\  VS_OUT o;
        \\  o.uv = float2((id << 1) & 2, id & 2);
        \\  o.pos = float4(o.uv * 2 - 1, 0, 1);
        \\  o.pos.y = -o.pos.y;
        \\  return o;
        \\}
    ;

    const ps_code =
        \\Texture2D tex : register(t0);
        \\SamplerState samp : register(s0);
        \\float4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
        \\  return tex.Sample(samp, uv);
        \\}
    ;

    const vs_blob = try compileShader(vs_code, "main", "vs_5_0");
    defer _ = vs_blob.lpVtbl.*.Release.?(@ptrCast(vs_blob));

    const ps_blob = try compileShader(ps_code, "main", "ps_5_0");
    defer _ = ps_blob.lpVtbl.*.Release.?(@ptrCast(ps_blob));

    const vs_data = vs_blob.lpVtbl.*.GetBufferPointer.?(vs_blob);
    const vs_size = vs_blob.lpVtbl.*.GetBufferSize.?(vs_blob);
    const ps_data = ps_blob.lpVtbl.*.GetBufferPointer.?(ps_blob);
    const ps_size = ps_blob.lpVtbl.*.GetBufferSize.?(ps_blob);

    var hr = device.?.lpVtbl.*.CreateVertexShader.?(device.?, vs_data, vs_size, null, @ptrCast(&vertex_shader));
    if (hr < 0) return error.CreateVSFailed;

    hr = device.?.lpVtbl.*.CreatePixelShader.?(device.?, ps_data, ps_size, null, @ptrCast(&pixel_shader));
    if (hr < 0) return error.CreatePSFailed;

    var samp_desc = std.mem.zeroes(c.D3D11_SAMPLER_DESC);
    samp_desc.Filter = c.D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samp_desc.AddressU = c.D3D11_TEXTURE_ADDRESS_CLAMP;
    samp_desc.AddressV = c.D3D11_TEXTURE_ADDRESS_CLAMP;
    samp_desc.AddressW = c.D3D11_TEXTURE_ADDRESS_CLAMP;

    hr = device.?.lpVtbl.*.CreateSamplerState.?(device.?, &samp_desc, @ptrCast(&sampler));
    if (hr < 0) return error.CreateSamplerFailed;
}

fn compileShader(code: []const u8, entry: [*:0]const u8, target: [*:0]const u8) !*c.ID3DBlob {
    var blob: ?*c.ID3DBlob = null;
    var error_blob: ?*c.ID3DBlob = null;

    const hr = c.D3DCompile(
        code.ptr,
        code.len,
        null,
        null,
        null,
        entry,
        target,
        c.D3DCOMPILE_OPTIMIZATION_LEVEL3,
        0,
        @ptrCast(&blob),
        @ptrCast(&error_blob),
    );

    if (hr < 0) {
        if (error_blob) |eb| {
            const err_msg = eb.lpVtbl.*.GetBufferPointer.?(eb);
            std.debug.print("Shader compile error: {s}\n", .{@as([*:0]const u8, @ptrCast(err_msg))});
            _ = eb.lpVtbl.*.Release.?(@ptrCast(eb));
        }
        return error.ShaderCompileFailed;
    }

    return blob.?;
}

fn render() void {
    var params = ViewParams{
        .center_x = @floatCast(state.center_x),
        .center_y = @floatCast(state.center_y),
        .scale = @floatCast(state.scale),
        .rotation = @floatCast(state.rotation),
        .width = state.width,
        .height = state.height,
        .max_iter = 256,
        .padding = 0,
    };

    var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
    _ = context.?.lpVtbl.*.Map.?(context.?, @ptrCast(const_buffer.?), 0, c.D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    @memcpy(@as([*]u8, @ptrCast(mapped.pData))[0..@sizeOf(ViewParams)], std.mem.asBytes(&params));
    context.?.lpVtbl.*.Unmap.?(context.?, @ptrCast(const_buffer.?), 0);

    context.?.lpVtbl.*.CSSetShader.?(context.?, compute_shader_obj.?, null, 0);
    context.?.lpVtbl.*.CSSetConstantBuffers.?(context.?, 0, 1, @ptrCast(&const_buffer));
    context.?.lpVtbl.*.CSSetUnorderedAccessViews.?(context.?, 0, 1, @ptrCast(&output_uav), null);

    const group_x = (state.width + 15) / 16;
    const group_y = (state.height + 15) / 16;
    context.?.lpVtbl.*.Dispatch.?(context.?, group_x, group_y, 1);

    var null_uav: ?*c.ID3D11UnorderedAccessView = null;
    context.?.lpVtbl.*.CSSetUnorderedAccessViews.?(context.?, 0, 1, @ptrCast(&null_uav), null);

    const clear_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    context.?.lpVtbl.*.ClearRenderTargetView.?(context.?, rtv.?, &clear_color);
    context.?.lpVtbl.*.OMSetRenderTargets.?(context.?, 1, @ptrCast(&rtv), null);

    var viewport = c.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(state.width),
        .Height = @floatFromInt(state.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    context.?.lpVtbl.*.RSSetViewports.?(context.?, 1, &viewport);

    context.?.lpVtbl.*.VSSetShader.?(context.?, vertex_shader.?, null, 0);
    context.?.lpVtbl.*.PSSetShader.?(context.?, pixel_shader.?, null, 0);
    context.?.lpVtbl.*.PSSetShaderResources.?(context.?, 0, 1, @ptrCast(&output_srv));
    context.?.lpVtbl.*.PSSetSamplers.?(context.?, 0, 1, @ptrCast(&sampler));
    context.?.lpVtbl.*.IASetPrimitiveTopology.?(context.?, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    context.?.lpVtbl.*.Draw.?(context.?, 3, 0);

    // Draw info overlay before present
    if (state.show_info) {
        drawInfoOverlay();
    }

    _ = swap_chain.?.lpVtbl.*.Present.?(swap_chain.?, 1, 0);
}

fn drawInfoOverlay() void {
    // Important: We need to flush D3D11 commands before getting the DC
    context.?.lpVtbl.*.Flush.?(context.?);
    
    var back_buffer: ?*c.ID3D11Texture2D = null;
    var hr = swap_chain.?.lpVtbl.*.GetBuffer.?(swap_chain.?, 0, &win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
    if (hr < 0) return;
    defer _ = back_buffer.?.lpVtbl.*.Release.?(@ptrCast(back_buffer.?));

    var dxgi_surface: ?*c.IDXGISurface1 = null;
    hr = back_buffer.?.lpVtbl.*.QueryInterface.?(@ptrCast(back_buffer.?), &win32.IID_IDXGISurface1, @ptrCast(&dxgi_surface));
    if (hr < 0) return;
    defer _ = dxgi_surface.?.lpVtbl.*.Release.?(@ptrCast(dxgi_surface.?));

    var hdc: c.HDC = undefined;
    hr = dxgi_surface.?.lpVtbl.*.GetDC.?(dxgi_surface.?, c.FALSE, &hdc);
    if (hr < 0) return;
    
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, 0x00FFFFFF);
    
    const hfont = c.CreateFontA(20, 0, 0, 0, c.FW_BOLD, 0, 0, 0,
        c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH | c.FF_DONTCARE, "Consolas");
    const old_font = c.SelectObject(hdc, hfont);

    var buf: [512]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf,
        "Center: ({d:.6}, {d:.6})\nScale: {d:.6}\nRotation: {d:.2} rad\nResolution: {}x{}\n\nControls:\nArrows: Zoom/Rotate | WASD: Move\nF1: Toggle Info | F11: Fullscreen\nESC/Ctrl+W: Exit",
        .{ state.center_x, state.center_y, state.scale, state.rotation, state.width, state.height }
    ) catch {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(hfont);
        _ = dxgi_surface.?.lpVtbl.*.ReleaseDC.?(dxgi_surface.?, null);
        return;
    };

    var rect = c.RECT{ .left = 10, .top = 10, .right = 600, .bottom = 300 };
    _ = c.DrawTextA(hdc, info.ptr, @intCast(info.len), &rect, c.DT_LEFT | c.DT_TOP);
    
    _ = c.SelectObject(hdc, old_font);
    _ = c.DeleteObject(hfont);
    
    // CRITICAL: Must release DC before any other D3D operations
    _ = dxgi_surface.?.lpVtbl.*.ReleaseDC.?(dxgi_surface.?, null);
}

fn updateWindowTitle() void {
    var buf: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&buf,
        "Mandelbrot Renderer (GPU Compute) | Press F1 for info",
        .{}
    ) catch return;

    _ = c.SetWindowTextA(hwnd_global, title.ptr);
}

fn handleResize(w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    if (swap_chain == null) return;
    
    state.width = w;
    state.height = h;

    if (rtv) |r| _ = r.lpVtbl.*.Release.?(@ptrCast(r));
    if (output_texture) |t| _ = t.lpVtbl.*.Release.?(@ptrCast(t));
    if (output_uav) |u| _ = u.lpVtbl.*.Release.?(@ptrCast(u));
    if (output_srv) |s| _ = s.lpVtbl.*.Release.?(@ptrCast(s));
    
    rtv = null;
    output_texture = null;
    output_uav = null;
    output_srv = null;

    // Resize with GDI compatibility flag preserved
    _ = swap_chain.?.lpVtbl.*.ResizeBuffers.?(swap_chain.?, 1, w, h, c.DXGI_FORMAT_B8G8R8A8_UNORM, c.DXGI_SWAP_CHAIN_FLAG_GDI_COMPATIBLE);

    createRenderTarget() catch return;
    
    var tex_desc = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
    tex_desc.Width = w;
    tex_desc.Height = h;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
    tex_desc.SampleDesc.Count = 1;
    tex_desc.Usage = c.D3D11_USAGE_DEFAULT;
    tex_desc.BindFlags = c.D3D11_BIND_UNORDERED_ACCESS | c.D3D11_BIND_SHADER_RESOURCE;

    _ = device.?.lpVtbl.*.CreateTexture2D.?(device.?, &tex_desc, null, @ptrCast(&output_texture));
    _ = device.?.lpVtbl.*.CreateUnorderedAccessView.?(device.?, @ptrCast(output_texture.?), null, @ptrCast(&output_uav));
    _ = device.?.lpVtbl.*.CreateShaderResourceView.?(device.?, @ptrCast(output_texture.?), null, @ptrCast(&output_srv));
}

fn handleInput(vk: c.WPARAM) void {
    const move_speed = state.scale * 0.1;
    const cos_r = @cos(state.rotation);
    const sin_r = @sin(state.rotation);

    switch (vk) {
        c.VK_UP => state.scale *= ZOOM_IN,
        c.VK_DOWN => state.scale *= ZOOM_OUT,
        c.VK_LEFT => state.rotation -= 0.1,
        c.VK_RIGHT => state.rotation += 0.1,
        'W' => {
            state.center_y -= move_speed * cos_r;
            state.center_x += move_speed * sin_r;
        },
        'S' => {
            state.center_y += move_speed * cos_r;
            state.center_x -= move_speed * sin_r;
        },
        'A' => {
            state.center_x -= move_speed * cos_r;
            state.center_y -= move_speed * sin_r;
        },
        'D' => {
            state.center_x += move_speed * cos_r;
            state.center_y += move_speed * sin_r;
        },
        c.VK_F1 => state.show_info = !state.show_info,
        c.VK_F11 => toggleFullscreen(),
        else => {},
    }
}

fn toggleFullscreen() void {
    if (state.is_fullscreen) {
        // Restore windowed mode
        _ = c.SetWindowLongPtrA(hwnd_global, c.GWL_STYLE, @intCast(state.windowed_style));
        _ = c.SetWindowPos(
            hwnd_global,
            null,
            state.windowed_rect.left,
            state.windowed_rect.top,
            state.windowed_rect.right - state.windowed_rect.left,
            state.windowed_rect.bottom - state.windowed_rect.top,
            c.SWP_FRAMECHANGED | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER,
        );
        state.is_fullscreen = false;
    } else {
        // Save current window state
        state.windowed_style = @intCast(c.GetWindowLongPtrA(hwnd_global, c.GWL_STYLE));
        _ = c.GetWindowRect(hwnd_global, &state.windowed_rect);

        // Get monitor info
        const monitor = c.MonitorFromWindow(hwnd_global, win32.MONITOR_DEFAULTTOPRIMARY);
        var mi = std.mem.zeroes(c.MONITORINFO);
        mi.cbSize = @sizeOf(c.MONITORINFO);
        _ = c.GetMonitorInfoA(monitor, &mi);

        // Set borderless fullscreen
        const new_style: c_ulong = @intCast(state.windowed_style & ~@as(c_longlong, c.WS_OVERLAPPEDWINDOW));
        _ = c.SetWindowLongPtrA(hwnd_global, c.GWL_STYLE, @intCast(new_style));
        _ = c.SetWindowPos(
            hwnd_global,
            win32.HWND_TOP,
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            c.SWP_FRAMECHANGED | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER,
        );
        state.is_fullscreen = true;
    }
}

fn windowProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.{ .x86_64_win = .{} }) c.LRESULT {
    switch (msg) {
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_SIZE => {
            const w: u32 = @intCast(lp & 0xFFFF);
            const h: u32 = @intCast((lp >> 16) & 0xFFFF);
            handleResize(w, h);
            return 0;
        },
        c.WM_KEYDOWN => {
            const ctrl_pressed = (c.GetKeyState(c.VK_CONTROL) & @as(c_short, @bitCast(@as(c_ushort, 0x8000)))) != 0;
            if (wp == c.VK_ESCAPE or (wp == 'W' and ctrl_pressed)) {
                c.PostQuitMessage(0);
                return 0;
            }
            handleInput(wp);
            return 0;
        },
        else => return c.DefWindowProcA(hwnd, msg, wp, lp),
    }
}

pub fn main() !void {
    const hInstance = c.GetModuleHandleA(null);

    const wc = c.WNDCLASSA{
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = c.LoadCursorA(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = "MandelbrotClass",
    };

    _ = c.RegisterClassA(&wc);

    // Calculate window size to get desired client area
    var rect = c.RECT{ .left = 0, .top = 0, .right = WIDTH, .bottom = HEIGHT };
    _ = c.AdjustWindowRect(&rect, c.WS_OVERLAPPEDWINDOW, c.FALSE);
    const window_width = rect.right - rect.left;
    const window_height = rect.bottom - rect.top;

    hwnd_global = c.CreateWindowExA(
        0,
        "MandelbrotClass",
        "Mandelbrot Renderer (GPU Compute)",
        c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        window_width,
        window_height,
        null,
        null,
        hInstance,
        null,
    );

    if (hwnd_global == null) return error.WindowCreationFailed;

    try initD3D(hwnd_global);

    var msg: c.MSG = undefined;
    var running = true;
    while (running) {
        while (c.PeekMessageA(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                running = false;
                break;
            }
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageA(&msg);
        }
        
        if (running) render();
    }
}