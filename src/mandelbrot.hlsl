cbuffer ViewParams : register(b0)
{
    float2 center;
    float scale;
    float rotation;
    uint2 resolution;
    uint maxIter;
    uint paletteIndex;
};

RWTexture2D<float4> output : register(u0);

float3 palette0(float t)
{
    // Classic smooth gradient
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.00, 0.10, 0.20);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 palette1(float t)
{
    // Fire colors
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 0.5);
    float3 d = float3(0.80, 0.90, 0.30);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 palette2(float t)
{
    // Ocean blues
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 palette3(float t)
{
    // Purple haze
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(2.0, 1.0, 0.0);
    float3 d = float3(0.50, 0.20, 0.25);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 palette4(float t)
{
    // Rainbow
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 palette5(float t)
{
    // Neon
    float3 a = float3(0.8, 0.5, 0.4);
    float3 b = float3(0.2, 0.4, 0.2);
    float3 c = float3(2.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.25, 0.25);
    return a + b * cos(6.28318 * (c * t + d));
}

float3 getPalette(float t, uint index)
{
    if (index == 0) return palette0(t);
    if (index == 1) return palette1(t);
    if (index == 2) return palette2(t);
    if (index == 3) return palette3(t);
    if (index == 4) return palette4(t);
    return palette5(t);
}

[numthreads(16, 16, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    if (DTid.x >= resolution.x || DTid.y >= resolution.y)
        return;

    float2 uv = float2(DTid.xy) / float2(resolution);
    uv = uv * 2.0 - 1.0;
    uv.x *= float(resolution.x) / float(resolution.y);

    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float2 rotated = float2(
        uv.x * cosR - uv.y * sinR,
        uv.x * sinR + uv.y * cosR
    );

    float2 c = center + rotated * scale;

    float2 z = float2(0.0, 0.0);
    uint iter = 0;
    
    [loop]
    for (iter = 0; iter < maxIter; iter++)
    {
        if (dot(z, z) > 4.0)
            break;
            
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = float2(x, y);
    }

    float3 color;
    if (iter == maxIter)
    {
        color = float3(0.0, 0.0, 0.0);
    }
    else
    {
        float smoothed = float(iter) + 1.0 - log2(log2(dot(z, z)));
        // Normalize by a fixed value instead of maxIter so colors are consistent
        float t = frac(smoothed * 0.05); // 0.05 gives nice color cycling
        color = getPalette(t, paletteIndex);
    }

    output[DTid.xy] = float4(color, 1.0);
}