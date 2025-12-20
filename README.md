# Mandelbrot Zig

A high-performance Mandelbrot set visualizer written in Zig. It leverages a DirectX 11 HLSL compute shader to render the fractal in real-time on Windows.

## Features

- Real-time Mandelbrot set rendering using GPU compute shaders.
- Multiple color palettes for varied fractal visualizations.
- Smooth zooming, movement, and rotation.
- Borderless fullscreen support.
- Live information overlay.

## Controls

| Key | Action |
|-----|--------|
| **W, A, S, D** | Move the view |
| **Up / Down Arrows** | Zoom in / Zoom out |
| **Left / Right Arrows** | Rotate the view |
| **[ / ]** | Decrease / Increase maximum iterations |
| **, / .** | Cycle through color palettes |
| **F1** | Toggle info overlay |
| **F11** | Toggle fullscreen |
| **ESC / Ctrl+W** | Exit |
