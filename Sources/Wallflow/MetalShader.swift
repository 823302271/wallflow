enum MetalShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOutput {
        float4 position [[position]];
    };

    struct WallpaperUniforms {
        float2 resolution;
        float2 mouse;
        float time;
        float activity;
        float intensity;
        float padding;
    };

    vertex VertexOutput wallpaperVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };

        VertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        return output;
    }

    float hash21(float2 point) {
        point = fract(point * float2(123.34, 456.21));
        point += dot(point, point + 45.32);
        return fract(point.x * point.y);
    }

    fragment float4 wallpaperFragment(
        VertexOutput input [[stage_in]],
        constant WallpaperUniforms &uniforms [[buffer(0)]]
    ) {
        float2 uv = input.position.xy / uniforms.resolution;
        float aspect = uniforms.resolution.x / uniforms.resolution.y;
        float2 point = uv - 0.5;
        point.x *= aspect;

        float2 mouse = uniforms.mouse - 0.5;
        mouse.x *= aspect;

        float2 mouseDelta = point - mouse;
        float mouseDistance = max(length(mouseDelta), 0.001);
        float mouseInfluence = exp(-mouseDistance * 5.5);
        point += (mouseDelta / mouseDistance) * mouseInfluence
            * (0.018 + 0.035 * uniforms.activity);

        float3 charcoal = float3(0.018, 0.027, 0.033);
        float3 deepTeal = float3(0.020, 0.105, 0.105);
        float3 color = mix(charcoal, deepTeal, smoothstep(-0.55, 0.6, point.y));

        float time = uniforms.time * 0.38;
        float aquaLines = 0.0;
        float warmLines = 0.0;

        for (int index = 0; index < 5; index++) {
            float layer = float(index);
            float phase = layer * 1.43;
            float frequency = 3.2 + layer * 0.52;
            float wave = sin(point.x * frequency + time * (0.62 + layer * 0.04) + phase);
            wave += sin(point.x * 1.7 - time * 0.31 + phase) * 0.24;

            float baseline = -0.42 + layer * 0.19;
            float cursorBend = (mouse.y - baseline) * mouseInfluence
                * (0.12 + uniforms.activity * 0.25);
            float lineY = baseline + wave * 0.075 + cursorBend;
            float distanceToLine = abs(point.y - lineY);
            float line = 1.0 - smoothstep(0.002, 0.012, distanceToLine);
            float glow = exp(-distanceToLine * 65.0) * 0.16;

            if ((index & 1) == 0) {
                aquaLines += line * 0.62 + glow;
            } else {
                warmLines += line * 0.42 + glow * 0.75;
            }
        }

        float ripple = sin(mouseDistance * 56.0 - uniforms.time * 4.2);
        ripple *= exp(-mouseDistance * 7.0) * uniforms.activity;
        float rippleLine = smoothstep(0.78, 1.0, ripple) * 0.34;

        float2 gridPoint = point + (mouse - point) * 0.015;
        float2 gridCell = abs(fract(gridPoint * float2(9.0, 6.0)) - 0.5);
        float grid = smoothstep(0.495, 0.48, min(gridCell.x, gridCell.y)) * 0.045;

        color += float3(0.12, 0.78, 0.68) * (aquaLines + rippleLine);
        color += float3(0.96, 0.34, 0.18) * warmLines;
        color += float3(0.18, 0.28, 0.27) * grid;

        float vignette = 1.0 - smoothstep(0.42, 0.92, length((uv - 0.5) * float2(0.8, 1.0)));
        color *= 0.72 + 0.28 * vignette;

        float grain = hash21(input.position.xy + uniforms.time) - 0.5;
        color += grain * 0.012;
        return float4(color * uniforms.intensity, 1.0);
    }
    """#
}
