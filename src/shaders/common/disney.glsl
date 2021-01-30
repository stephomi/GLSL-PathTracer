/*
 * MIT License
 *
 * Copyright(c) 2019-2021 Asif Ali
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files(the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions :
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

 /* References:
 * [1] https://media.disneyanimation.com/uploads/production/publication_asset/48/asset/s2012_pbs_disney_brdf_notes_v3.pdf
 * [2] https://blog.selfshadow.com/publications/s2015-shading-course/burley/s2015_pbs_disney_bsdf_notes.pdf
 * [3] https://github.com/wdas/brdf/blob/main/src/brdfs/disney.brdf
 * [4] https://github.com/mmacklin/tinsel/blob/master/src/disney.h
 * [5] http://simon-kallweit.me/rendercompo2015/report/
 * [6] http://shihchinw.github.io/2015/07/implementing-disney-principled-brdf-in-arnold.html
 * [7] https://github.com/mmp/pbrt-v4/blob/0ec29d1ec8754bddd9d667f0e80c4ff025c900ce/src/pbrt/bxdfs.cpp#L76-L286
 * [8] https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.pdf
 * [9] https://graphics.pixar.com/library/RadiosityCaching/paper.pdf
 */

 //-----------------------------------------------------------------------
float DisneyPdf(in Ray ray, inout State state, in vec3 bsdfDir)
//-----------------------------------------------------------------------
{
    vec3 N = state.ffnormal;
    vec3 V = -ray.direction;
    vec3 L = bsdfDir;
    vec3 H;

    if (dot(N, L) < 0.0)
    {
        H = -normalize(L * (1.0 / state.eta) + V);
        if (dot(N, H) < 0.0)
            H = -H;
    }
    else
        H = normalize(L + V);

    float NDotH = dot(N, H);
    float VDotH = dot(V, H);
    float LDotH = dot(L, H);
    float NDotL = dot(N, L);
    float NDotV = dot(N, V);

    float specularAlpha = max(0.001, state.mat.roughness);
    float clearcoatAlpha = mix(0.1, 0.001, state.mat.clearcoatGloss);

    float diffuseRatio = 0.5 * (1.0 - state.mat.metallic);
    float specularRatio = 1.0 - diffuseRatio;

    float transWeight = (1.0 - state.mat.metallic) * state.mat.specTrans;

    float brdfPdf = 0.0;
    float bsdfPdf = 0.0;

    // Handle transmission/subsurface separately
    if (dot(N, L) < 0.0)
    {
        // Subsurface
        brdfPdf = (1.0 / TWO_PI) * state.mat.subsurface * diffuseRatio;

        // Transmission
        float pdfGTR2 = GTR2(NDotH, specularAlpha) * NDotH;
        float F = DielectricFresnel(abs(VDotH), state.eta);
        float denomSqrt = LDotH * state.eta + VDotH;
        bsdfPdf = pdfGTR2 * (1.0 - F) * abs(LDotH) / (denomSqrt * denomSqrt);
    }
    else
    {
        // BRDF Reflection
        float pdfGTR2_aniso = GTR2_aniso(NDotH, dot(H, state.tangent), dot(H, state.bitangent), state.mat.ax, state.mat.ay) * NDotH;
        float pdfGTR1 = GTR1(NDotH, clearcoatAlpha) * NDotH;
        float ratio = 1.0 / (1.0 + state.mat.clearcoat);
        float pdfSpec = mix(pdfGTR1, pdfGTR2_aniso, ratio) / (4.0 * VDotH);
        float pdfDiff = NDotL * (1.0 / PI) * (1.0 - state.mat.subsurface);
        brdfPdf = mix(pdfSpec, pdfDiff, diffuseRatio);

        // BSDF Reflection
        float pdfGTR2 = GTR2(NDotH, specularAlpha) * NDotH;
        float F = DielectricFresnel(VDotH, state.eta);
        bsdfPdf = pdfGTR2 * F / (4.0 * VDotH);
    }

    return mix(brdfPdf, bsdfPdf, transWeight);
}

//-----------------------------------------------------------------------
void EvalDielectricReflection(State state, inout BsdfSampleRec bRec)
//-----------------------------------------------------------------------
{
    float F = DielectricFresnel(dot(bRec.V, bRec.H), state.eta);
    float D = GTR2(dot(bRec.N, bRec.H), state.mat.roughness);
    
    bRec.pdf = D * dot(bRec.N, bRec.H) / (4.0 * dot(bRec.V, bRec.H));

    float G = SmithG_GGX(abs(dot(bRec.N, bRec.L)), state.mat.roughness) * SmithG_GGX(dot(bRec.N, bRec.V), state.mat.roughness);
    bRec.f = state.mat.albedo * F * D * G;
}

//-----------------------------------------------------------------------
void EvalDielectricRefraction(State state, inout BsdfSampleRec bRec)
//-----------------------------------------------------------------------
{
    float F = DielectricFresnel(dot(bRec.V, bRec.H), state.eta);
    float D = GTR2(dot(bRec.N, bRec.H), state.mat.roughness);

    float denomSqrt = dot(bRec.L, bRec.H) * state.eta + dot(bRec.V, bRec.H);
    bRec.pdf = D * abs(dot(bRec.L, bRec.H)) / (denomSqrt * denomSqrt);

    float G = SmithG_GGX(abs(dot(bRec.N, bRec.L)), state.mat.roughness) * SmithG_GGX(dot(bRec.N, bRec.V), state.mat.roughness);
    bRec.f = state.mat.albedo * (1.0 - F) * D * G * abs(dot(bRec.V, bRec.H)) * abs(dot(bRec.L, bRec.H)) * 4.0 * state.eta * state.eta / (denomSqrt * denomSqrt);
}

//-----------------------------------------------------------------------
void EvalSpecular(State state, inout BsdfSampleRec bRec, vec3 Cspec0)
//-----------------------------------------------------------------------
{
    float D = GTR2_aniso(dot(bRec.N, bRec.H), dot(bRec.H, state.tangent), dot(bRec.H, state.bitangent), state.mat.ax, state.mat.ay);
    bRec.pdf = D * dot(bRec.N, bRec.H) / (4.0 * dot(bRec.V, bRec.H));

    float FH = SchlickFresnel(dot(bRec.L, bRec.H));
    vec3 F = mix(Cspec0, vec3(1.0), FH);
    float G = SmithG_GGX_aniso(dot(bRec.N, bRec.L), dot(bRec.L, state.tangent), dot(bRec.L, state.bitangent), state.mat.ax, state.mat.ay);
    G *= SmithG_GGX_aniso(dot(bRec.N, bRec.V), dot(bRec.V, state.tangent), dot(bRec.V, state.bitangent), state.mat.ax, state.mat.ay);
    bRec.f = F * D * G;
}

//-----------------------------------------------------------------------
void EvalClearcoat(State state, inout BsdfSampleRec bRec, float clearcoatAlpha)
//-----------------------------------------------------------------------
{
    float D = GTR1(dot(bRec.N, bRec.H), clearcoatAlpha);
    bRec.pdf = D * dot(bRec.N, bRec.H) / (4.0 * dot(bRec.V, bRec.H));

    float FH = SchlickFresnel(dot(bRec.L, bRec.H));
    float F = mix(0.04, 1.0, FH);
    float G = SmithG_GGX(dot(bRec.N, bRec.L), 0.25) * SmithG_GGX(dot(bRec.N, bRec.V), 0.25);
    bRec.f = vec3(0.25 * state.mat.clearcoat * F * D * G);
}

//-----------------------------------------------------------------------
void EvalDiffuse(State state, inout BsdfSampleRec bRec, vec3 Csheen)
//-----------------------------------------------------------------------
{
    bRec.pdf = dot(bRec.N, bRec.L) * (1.0 / PI);

    float FL = SchlickFresnel(abs(dot(bRec.N, bRec.L)));
    float FV = SchlickFresnel(dot(bRec.N, bRec.V));
    float FH = SchlickFresnel(dot(bRec.L, bRec.H));
    float Fd90 = 0.5 + 2.0 * dot(bRec.L, bRec.H) * dot(bRec.L, bRec.H) * state.mat.roughness;
    float Fd = mix(1.0, Fd90, FL) * mix(1.0, Fd90, FV);
    vec3 Fsheen = FH * state.mat.sheen * Csheen;
    bRec.f = ((1.0 / PI) * Fd * (1.0 - state.mat.subsurface) * state.mat.albedo + Fsheen) * (1.0 - state.mat.metallic);
}

//-----------------------------------------------------------------------
void EvalSubsurface(State state, inout BsdfSampleRec bRec)
//-----------------------------------------------------------------------
{
    bRec.pdf = (1.0 / TWO_PI);

    float FL = SchlickFresnel(abs(dot(bRec.N, bRec.L)));
    float FV = SchlickFresnel(dot(bRec.N, bRec.V));
    float Fd = (1.0f - 0.5f * FL) * (1.0f - 0.5f * FV);
    bRec.f = sqrt(state.mat.albedo) * (1.0 / PI) * Fd * (1.0 - state.mat.metallic);
}

//-----------------------------------------------------------------------
vec3 DisneySample(inout State state, inout BsdfSampleRec bRec)
//-----------------------------------------------------------------------
{
    state.isSubsurface = false;
    bRec.f = vec3(0.0);
    bRec.pdf = 0.0;

    float r1 = rand();
    float r2 = rand();

    float diffuseRatio = 0.5 * (1.0 - state.mat.metallic);
    float transWeight = (1.0 - state.mat.metallic) * state.mat.specTrans;

    vec3 Cdlin = state.mat.albedo;
    float Cdlum = 0.3 * Cdlin.x + 0.6 * Cdlin.y + 0.1 * Cdlin.z; // luminance approx.

    vec3 Ctint = Cdlum > 0.0 ? Cdlin / Cdlum : vec3(1.0f); // normalize lum. to isolate hue+sat
    vec3 Cspec0 = mix(state.mat.specular * 0.08 * mix(vec3(1.0), Ctint, state.mat.specularTint), Cdlin, state.mat.metallic);
    vec3 Csheen = mix(vec3(1.0), Ctint, state.mat.sheenTint);

    // BSDF
    if (rand() < transWeight)
    {
        vec3 H = ImportanceSampleGTR2(state.mat.roughness, r1, r2);
        bRec.H = state.tangent * H.x + state.bitangent * H.y + bRec.N * H.z;

        vec3 R = reflect(-bRec.V, bRec.H);
        float F = DielectricFresnel(abs(dot(R, bRec.H)), state.eta);

        if (rand() < F) // Reflection/Total internal reflection
        {
            bRec.L = normalize(R); 

            if (dot(bRec.N, bRec.L) < 0.0)
                return vec3(0.0);

            EvalDielectricReflection(state, bRec);
            bRec.pdf *= F * transWeight;

        }
        else // Transmission
        {
            bRec.L = normalize(refract(-bRec.V, bRec.H, state.eta));

            EvalDielectricRefraction(state, bRec);
            bRec.pdf *= (1.0 - F) * transWeight;
        }
    }
    // BRDF
    else
    {
        if (rand() < diffuseRatio)
        {
            // This way of performing subsurface scattering was taken from Tinsel [4] and is similar [9].
            // Simpler than random walk but not sure if accurate.
            if (rand() < state.mat.subsurface)
            {
                vec3 L = UniformSampleHemisphere(r1, r2);
                bRec.L = state.tangent * L.x + state.bitangent * L.y - bRec.N * L.z;

                EvalSubsurface(state, bRec);
                bRec.pdf *= state.mat.subsurface * diffuseRatio * (1.0 - transWeight);

                state.isSubsurface = true; // Required when sampling lights from inside surface
            }
            else
            {
                vec3 L = CosineSampleHemisphere(r1, r2);
                bRec.L = state.tangent * L.x + state.bitangent * L.y + bRec.N * L.z;

                if (dot(bRec.N, bRec.L) < 0.0)
                    return vec3(0.0);

                bRec.H = normalize(bRec.L + bRec.V);

                EvalDiffuse(state, bRec, Csheen);
                bRec.pdf *= (1.0 - state.mat.subsurface) * diffuseRatio * (1.0 - transWeight);
            }
        }
        else
        {
            float lobeRatio = 1.0 / (1.0 + state.mat.clearcoat);
            
            // TODO: Implement http://jcgt.org/published/0007/04/01/
            if (rand() < lobeRatio) // Sample primary specular lobe
            {
                vec3 H = ImportanceSampleGTR2_aniso(state.mat.ax, state.mat.ay, r1, r2);
                bRec.H = normalize(state.tangent * H.x + state.bitangent * H.y + bRec.N * H.z);
                bRec.L = reflect(-bRec.V, bRec.H);

                if (dot(bRec.N, bRec.L) < 0.0)
                    return vec3(0.0);

                EvalSpecular(state, bRec, Cspec0);
                bRec.pdf *= lobeRatio * (1.0 - diffuseRatio) * (1.0 - transWeight);
            }
            else // Sample clearcoat lobe
            {
                float clearcoatAlpha = mix(0.1, 0.001, state.mat.clearcoatGloss);

                vec3 H = ImportanceSampleGTR1(clearcoatAlpha, r1, r2);
                bRec.H = normalize(state.tangent * H.x + state.bitangent * H.y + bRec.N * H.z);
                bRec.L = reflect(-bRec.V, bRec.H);

                if (dot(bRec.N, bRec.L) < 0.0)
                    return vec3(0.0);

                EvalClearcoat(state, bRec, clearcoatAlpha);
                bRec.pdf *= (1.0 - lobeRatio) * (1.0 - diffuseRatio) * (1.0 - transWeight);
            }
        }
    }
}

//-----------------------------------------------------------------------
vec3 DisneyEval(in Ray ray, inout State state, in vec3 bsdfDir)
//-----------------------------------------------------------------------
{
    vec3 N = state.ffnormal;
    vec3 V = -ray.direction;
    vec3 L = bsdfDir;
    vec3 H;

    if (dot(N, L) < 0.0)
    {
        H = -normalize(L * (1.0 / state.eta) + V);
        if (dot(N, H) < 0.0)
            H = -H;
    }
    else
        H = normalize(L + V);

    float NDotL = dot(N, L);
    float NDotV = dot(N, V);
    float NDotH = dot(N, H);
    float VDotH = dot(V, H);
    float LDotH = dot(L, H);

    vec3 brdf = vec3(0.0);
    vec3 bsdf = vec3(0.0);

    float transWeight = (1.0 - state.mat.metallic) * state.mat.specTrans;

    // BSDF
    if (transWeight > 0.0)
    {
        float a = max(0.001, state.mat.roughness);
        float F = DielectricFresnel(abs(VDotH), state.eta);
        float D = GTR2(NDotH, a);
        float G = SmithG_GGX(abs(NDotL), a) * SmithG_GGX(NDotV, a);

        if (dot(N, L) < 0.0)
        {
            float denomSqrt = LDotH * state.eta + VDotH;
            bsdf = state.mat.albedo * (1.0 - F) * D * G * abs(VDotH) * abs(LDotH) * 4.0 * state.eta * state.eta / (denomSqrt * denomSqrt);
        }
        else
        {
            bsdf = state.mat.albedo * F * D * G;
        }
    }

    if (transWeight < 1.0)
    {
        float FL = SchlickFresnel(abs(NDotL));
        float FV = SchlickFresnel(NDotV);

        // Subsurface
        if (dot(N, L) < 0.0)
        {
            if (state.mat.subsurface > 0.0)
            {
                float Fd = (1.0f - 0.5f * FL) * (1.0f - 0.5f * FV);
                brdf = sqrt(state.mat.albedo) * 1.0 / PI * Fd * (1.0 - state.mat.metallic);
            }
        }
        // BRDF
        else
        {
            vec3 Cdlin = state.mat.albedo;
            float Cdlum = 0.3 * Cdlin.x + 0.6 * Cdlin.y + 0.1 * Cdlin.z; // luminance approx.

            vec3 Ctint = Cdlum > 0.0 ? Cdlin / Cdlum : vec3(1.0f); // normalize lum. to isolate hue+sat
            vec3 Cspec0 = mix(state.mat.specular * 0.08 * mix(vec3(1.0), Ctint, state.mat.specularTint), Cdlin, state.mat.metallic);
            vec3 Csheen = mix(vec3(1.0), Ctint, state.mat.sheenTint);

            // Diffuse fresnel - go from 1 at normal incidence to .5 at grazing
            // and mix in diffuse retro-reflection based on roughness
            float Fd90 = 0.5 + 2.0 * LDotH * LDotH * state.mat.roughness;
            float Fd = mix(1.0, Fd90, FL) * mix(1.0, Fd90, FV);

            // TODO: Add anisotropic rotation
            // specular
            float Ds = GTR2_aniso(NDotH, dot(H, state.tangent), dot(H, state.bitangent), state.mat.ax, state.mat.ay);
            float FH = SchlickFresnel(LDotH);
            vec3 Fs = mix(Cspec0, vec3(1.0), FH);
            float Gs = SmithG_GGX_aniso(NDotL, dot(L, state.tangent), dot(L, state.bitangent), state.mat.ax, state.mat.ay);
            Gs *= SmithG_GGX_aniso(NDotV, dot(V, state.tangent), dot(V, state.bitangent), state.mat.ax, state.mat.ay);

            // sheen
            vec3 Fsheen = FH * state.mat.sheen * Csheen;

            // clearcoat (ior = 1.5 -> F0 = 0.04)
            float Dr = GTR1(NDotH, mix(0.1, 0.001, state.mat.clearcoatGloss));
            float Fr = mix(0.04, 1.0, FH);
            float Gr = SmithG_GGX(NDotL, 0.25) * SmithG_GGX(NDotV, 0.25);

            brdf = ((1.0 / PI) * Fd * (1.0 - state.mat.subsurface) * Cdlin + Fsheen) * (1.0 - state.mat.metallic)
                    + Gs * Fs * Ds
                    + 0.25 * state.mat.clearcoat * Gr * Fr * Dr;
        }
    }

    return mix(brdf, bsdf, transWeight);

}
