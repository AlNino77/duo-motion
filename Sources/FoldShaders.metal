#include <metal_stdlib>
using namespace metal;

constant float MAX_TILT = 0.84106867; // acos(1.0 / 1.5)
constant float3 DARK = float3(0.003, 0.004, 0.005);

struct Uniforms {
    float2 imageSize;
    float2 cover;
    float aspect;
    float turn;
    float closureProgress;
    float motionDirection;
    float blurStrength;
    float reflectionIntensity;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut foldVertex(uint vid [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    
    VertexOut out;
    float2 pos = positions[vid];
    out.position = float4(pos, 0.0, 1.0);
    // UV origin: (0,0) at top-left, (1,1) at bottom-right.
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return out;
}

inline float3 sampleSmoothMatteBlur(texture2d<float> tex,
                                    sampler s,
                                    float2 uv,
                                    float radius,
                                    float2 cover,
                                    float2 uiPixel,
                                    float2 screenCoord) {
    float2 tuv = (uv - 0.5) * cover + 0.5;
    
    if (radius <= 0.15) {
        return tex.sample(s, tuv, level(0.0)).rgb;
    }
    
    // Keep mip levels tight so the frosted region stays continuous instead of
    // turning into visible blocks on a Retina display.
    float baseLod = clamp(log2(max(1.0, radius * 0.18)), 0.0, 1.85);
    
    // Per-pixel micro rotation breaks up concentric sampling bands.
    float rot = (fract(sin(dot(screenCoord, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.35;
    float cosRot = cos(rot);
    float sinRot = sin(rot);
    
    float3 accum = float3(0.0);
    float totalWeight = 0.0;
    
    constexpr int NUM_SAMPLES = 32;
    constexpr float GOLDEN_ANGLE = 2.39996323;
    
    for (int i = 0; i < NUM_SAMPLES; i++) {
        float fi = float(i);
        float theta = fi * GOLDEN_ANGLE;
        float r = sqrt((fi + 0.5) / float(NUM_SAMPLES));
        
        float uX = cos(theta);
        float uY = sin(theta);
        float dirX = uX * cosRot - uY * sinRot;
        float dirY = uX * sinRot + uY * cosRot;
        
        float2 offset = float2(dirX, dirY) * (r * radius * uiPixel);
        float2 sampleUV = clamp(tuv + offset, 0.0, 1.0);
        
        float weight = exp(-2.3 * r * r);
        float sampleLod = mix(0.0, baseLod, smoothstep(0.1, 0.85, r));
        
        accum += tex.sample(s, sampleUV, level(sampleLod)).rgb * weight;
        totalWeight += weight;
    }
    
    float3 blurred = accum / totalWeight;
    float matteScatter = 0.015 * smoothstep(0.0, 20.0, radius);
    blurred += float3(matteScatter);
    
    float3 sharp = tex.sample(s, tuv, level(0.0)).rgb;
    return mix(sharp, blurred, smoothstep(0.0, 2.0, radius));
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant Uniforms &u [[buffer(0)]]) {
    float effect = clamp(u.turn, 0.0, 1.0);
    float closure = clamp(u.closureProgress, 0.0, 1.0);
    float opening = u.motionDirection < -0.5 ? 1.0 : 0.0;
    float2 uiPixel = 2.0 / max(float2(1.0), u.imageSize);
    
    if (effect <= 0.00001 && closure <= 0.00001) {
        return float4(sampleSmoothMatteBlur(tex, s, in.uv, 0.0, u.cover, uiPixel, in.position.xy), 1.0);
    }
    
    // Bottom-hinge clamshell geometry. The content closest to the hinge remains
    // visually anchored while the upper display travels deeper into perspective.
    float fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
    float geometryTurn = smoothstep(0.0, 1.0, effect);
    float bend = geometryTurn * MAX_TILT;
    float cosine = cos(bend);
    float sine = sin(bend);
    
    float invAspect = 1.0 / max(0.1, u.aspect);
    float eye = 3.2 * max(invAspect, 1.0);
    float depth = fromHinge * (0.80 * invAspect) * sine;
    float perspective = eye / max(0.01, eye - depth);
    
    float2 plane;
    plane.y = 1.0 - fromHinge * cosine * perspective;
    plane.x = 0.5 + (in.uv.x - 0.5) * perspective;
    
    // Optical defocus is spatial, not a full-screen blur. The hinge edge remains
    // almost sharp while the far edge progressively frosts over.
    float blurSpread = pow(smoothstep(0.03, 0.98, fromHinge), 1.55);
    
    // Opening is intentionally not closing-in-reverse. Focus lags slightly behind
    // the returning geometry, so the image seems to emerge from depth before snapping
    // back into the physical LCD plane near the end of the opening motion.
    float closingBlurTurn = pow(effect, 1.35);
    float openingBlurTurn = pow(effect, 0.72);
    float blurTurn = mix(closingBlurTurn, openingBlurTurn, opening);
    blurTurn = smoothstep(0.025, 1.0, blurTurn);
    
    float localBlur = mix(0.02, 1.0, blurSpread);
    float radius = 60.0 * blurTurn * localBlur * max(0.05, u.blurStrength);
    
    float softness = fwidth(in.uv.x) + radius * 0.0017;
    float mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.x - 0.5));
    
    float3 color = sampleSmoothMatteBlur(tex, s, plane, radius, u.cover, uiPixel, in.position.xy);
    
    // Glass behavior: gentle absorption plus a broad specular band. Opening gets a
    // small reflection lift so the surface reads as glass before full sharpness returns.
    float glass = sine * pow(fromHinge, 1.45);
    color *= 1.0 - 0.16 * glass;
    
    float reflectionBand = exp(-pow((fromHinge - 0.64) / 0.34, 2.0));
    float reflectionPhase = smoothstep(0.05, 0.95, effect) * sine;
    float openingReflectionBoost = mix(1.0, 1.15, opening);
    color += float3(0.82, 0.85, 0.87)
        * reflectionBand
        * reflectionPhase
        * openingReflectionBoost
        * (0.028 * u.reflectionIntensity);
    
    // Depth darkness remains spatial during the main fold. The remaining physical
    // travel below ~60° is a separate closure phase that pulls the scene into black.
    float fadeDistance = clamp((fromHinge - 0.16) / 0.84, 0.0, 1.0);
    float closingVoidTurn = pow(effect, 1.22);
    float openingVoidTurn = pow(effect, 1.50);
    float voidTurn = mix(closingVoidTurn, openingVoidTurn, opening);
    
    float spatialVoid = 0.64 * voidTurn * fadeDistance;
    float closureVoid = 0.92 * pow(closure, 1.08) * (0.18 + 0.82 * fadeDistance);
    float voidAmount = clamp(spatialVoid + closureVoid, 0.0, 1.0);
    color *= 1.0 - 0.86 * voidAmount;
    
    // Global blackout happens only at the very end of the physical close. This keeps
    // the 60° "full effect" frame dimensional instead of prematurely making it black.
    float finalVisible = 1.0 - smoothstep(0.72, 1.0, closure);
    float visible = mask * finalVisible;
    
    return float4(mix(DARK, color, visible), 1.0);
}
