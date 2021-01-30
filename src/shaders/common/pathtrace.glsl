/*
 * MIT License
 *
 * Copyright(c) 2019-2021 Asif Ali
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this softwareand associated documentation files(the "Software"), to deal
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

//-----------------------------------------------------------------------
void Onb(in vec3 N, inout vec3 T, inout vec3 B)
//-----------------------------------------------------------------------
{
    vec3 UpVector = abs(N.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
    T = normalize(cross(UpVector, N));
    B = cross(N, T);
}

//-----------------------------------------------------------------------
void GetNormalsAndTexCoord(inout State state, inout Ray r)
//-----------------------------------------------------------------------
{
    vec4 n1 = texelFetch(normalsTex, state.triID.x);
    vec4 n2 = texelFetch(normalsTex, state.triID.y);
    vec4 n3 = texelFetch(normalsTex, state.triID.z);

    vec2 t1 = vec2(tempTexCoords.x, n1.w);
    vec2 t2 = vec2(tempTexCoords.y, n2.w);
    vec2 t3 = vec2(tempTexCoords.z, n3.w);

    state.texCoord = t1 * state.bary.x + t2 * state.bary.y + t3 * state.bary.z;

    vec3 normal = normalize(n1.xyz * state.bary.x + n2.xyz * state.bary.y + n3.xyz * state.bary.z);

    mat3 normalMatrix = transpose(inverse(mat3(transform)));
    normal = normalize(normalMatrix * normal);
    state.normal = normal;
    state.ffnormal = dot(normal, r.direction) <= 0.0 ? normal : normal * -1.0;

    Onb(state.ffnormal, state.tangent, state.bitangent);
}

//-----------------------------------------------------------------------
void GetMaterialsAndTextures(inout State state, in Ray r)
//-----------------------------------------------------------------------
{
    int index = state.matID;
    Material mat;

    vec4 param1 = texelFetch(materialsTex, ivec2(index * 6 + 0, 0), 0);
    vec4 param2 = texelFetch(materialsTex, ivec2(index * 6 + 1, 0), 0);
    vec4 param3 = texelFetch(materialsTex, ivec2(index * 6 + 2, 0), 0);
    vec4 param4 = texelFetch(materialsTex, ivec2(index * 6 + 3, 0), 0);
    vec4 param5 = texelFetch(materialsTex, ivec2(index * 6 + 4, 0), 0);
    vec4 param6 = texelFetch(materialsTex, ivec2(index * 6 + 5, 0), 0);

    mat.albedo         = param1.xyz;
    mat.specular       = param1.w;

    mat.emission       = param2.xyz;
    mat.anisotropic    = param2.w;

    mat.metallic       = param3.x;
    mat.roughness      = max(param3.y, 0.001);

    mat.subsurface     = param3.z;
    mat.specularTint   = param3.w;

    mat.sheen          = param4.x;
    mat.sheenTint      = param4.y;
    mat.clearcoat      = param4.z;
    mat.clearcoatGloss = param4.w;

    mat.specTrans      = param5.x;
    mat.ior            = param5.y;

    mat.extinction     = vec3(param5.zw, param6.x);
    mat.texIDs         = vec3(param6.yzw);

    vec2 texUV = state.texCoord;
    texUV.y = 1.0 - texUV.y;

    // Albedo Map
    if (int(mat.texIDs.x) >= 0)
        mat.albedo *= pow(texture(textureMapsArrayTex, vec3(texUV, int(mat.texIDs.x))).xyz, vec3(2.2));

    // Metallic Roughness Map
    if (int(mat.texIDs.y) >= 0)
    {
        vec2 matRgh;
        matRgh = pow(texture(textureMapsArrayTex, vec3(texUV, int(mat.texIDs.y))).zy, vec2(2.2));
        mat.metallic = matRgh.x;
        mat.roughness = matRgh.y;
    }

    // Normal Map
    if (int(mat.texIDs.z) >= 0)
    {
        vec3 nrm = texture(textureMapsArrayTex, vec3(texUV, int(mat.texIDs.z))).xyz;
        nrm = normalize(nrm * 2.0 - 1.0);

        // Orthonormal Basis
        vec3 T, B;
        Onb(state.ffnormal, T, B);

        nrm = T * nrm.x + B * nrm.y + state.ffnormal * nrm.z;
        state.normal = normalize(nrm);
        state.ffnormal = dot(state.normal, r.direction) <= 0.0 ? state.normal : state.normal * -1.0;

        Onb(state.ffnormal, state.tangent, state.bitangent);
    }

    // Calculate anisotropic roughness along the tangent and bitangent directions
    float aspect = sqrt(1.0 - mat.anisotropic * 0.9);
    mat.ax = max(0.001, mat.roughness / aspect);
    mat.ay = max(0.001, mat.roughness * aspect);

    state.mat = mat;
    state.eta = dot(state.normal, state.ffnormal) > 0.0 ? (1.0 / mat.ior) : mat.ior;
}

//-----------------------------------------------------------------------
vec3 DirectLight(in Ray r, in State state)
//-----------------------------------------------------------------------
{
    vec3 L = vec3(0.0);
    BsdfSampleRec bsdfSampleRec;

    vec3 surfacePos = state.fhp + state.normal * EPS;

    // Environment Light
#ifdef ENVMAP
#ifndef CONSTANT_BG
    {
        vec3 color;
        vec4 dirPdf = EnvSample(color);
        vec3 lightDir = dirPdf.xyz;
        float lightPdf = dirPdf.w;

        if (state.isSubsurface || dot(lightDir, state.ffnormal) > 0.0)
        {
            Ray shadowRay = Ray(surfacePos, lightDir);
            bool inShadow = AnyHit(shadowRay, INFINITY - EPS);

            if (!inShadow)
            {
                float bsdfPdf = DisneyPdf(r, state, lightDir);
                vec3 f = DisneyEval(r, state, lightDir);

                if (bsdfPdf > 0.0)
                {
                    float misWeight = powerHeuristic(lightPdf, bsdfPdf);
                    if (misWeight > 0.0)
                        L += misWeight * f * abs(dot(lightDir, state.ffnormal)) * color / lightPdf;
                }
            }
        }
    }
#endif
#endif

    // Analytic Lights 
#ifdef LIGHTS
    {
        LightSampleRec lightSampleRec;
        Light light;

        //Pick a light to sample
        int index = int(rand() * float(numOfLights));

        // Fetch light Data
        vec3 position = texelFetch(lightsTex, ivec2(index * 5 + 0, 0), 0).xyz;
        vec3 emission = texelFetch(lightsTex, ivec2(index * 5 + 1, 0), 0).xyz;
        vec3 u        = texelFetch(lightsTex, ivec2(index * 5 + 2, 0), 0).xyz; // u vector for rect
        vec3 v        = texelFetch(lightsTex, ivec2(index * 5 + 3, 0), 0).xyz; // v vector for rect
        vec3 params   = texelFetch(lightsTex, ivec2(index * 5 + 4, 0), 0).xyz;
        float radius  = params.x;
        float area    = params.y;
        float type    = params.z; // 0->rect, 1->sphere

        light = Light(position, emission, u, v, radius, area, type);
        sampleLight(light, lightSampleRec);

        vec3 lightDir = lightSampleRec.surfacePos - surfacePos;
        float lightDist = length(lightDir);
        float lightDistSq = lightDist * lightDist;
        lightDir /= sqrt(lightDistSq);

        if (!state.isSubsurface && (dot(lightDir, state.ffnormal) <= 0.0 || dot(lightDir, lightSampleRec.normal) >= 0.0))
            return L;

        Ray shadowRay = Ray(surfacePos, lightDir);
        bool inShadow = AnyHit(shadowRay, lightDist - EPS);

        if (!inShadow)
        {
            float bsdfPdf = DisneyPdf(r, state, lightDir);
            vec3 f = DisneyEval(r, state, lightDir);
            float lightPdf = lightDistSq / (light.area * abs(dot(lightSampleRec.normal, lightDir)));

            if (bsdfPdf > 0.0)
                L += powerHeuristic(lightPdf, bsdfPdf) * f * abs(dot(state.ffnormal, lightDir)) * lightSampleRec.emission / lightPdf;
        }
    }
#endif

    return L;
}


//-----------------------------------------------------------------------
vec3 PathTrace(Ray r)
//-----------------------------------------------------------------------
{
    vec3 radiance = vec3(0.0);
    vec3 throughput = vec3(1.0);
    State state;
    LightSampleRec lightSampleRec;
    BsdfSampleRec bsdfSampleRec;
    vec3 absorption = vec3(0.0);
    
    for (int depth = 0; depth < maxDepth; depth++)
    {
        float lightPdf = 1.0f;
        state.depth = depth;
        float t = ClosestHit(r, state, lightSampleRec);

        if (t == INFINITY)
        {
#ifdef CONSTANT_BG
            radiance += bgColor * throughput;
#else
#ifdef ENVMAP
            {
                float misWeight = 1.0f;
                vec2 uv = vec2((PI + atan(r.direction.z, r.direction.x)) * (1.0 / TWO_PI), acos(r.direction.y) * (1.0 / PI));

                if (depth > 0 && !state.specularBounce)
                {
                    // TODO: Fix NaNs when using certain HDRs
                    lightPdf = EnvPdf(r);
                    misWeight = powerHeuristic(bsdfSampleRec.pdf, lightPdf);
                }
                radiance += misWeight * texture(hdrTex, uv).xyz * throughput * hdrMultiplier;
            }
#endif
#endif
            return radiance;
        }

        GetNormalsAndTexCoord(state, r);
        GetMaterialsAndTextures(state, r);

        bsdfSampleRec.V = -r.direction;
        bsdfSampleRec.N = state.ffnormal;

        if (dot(state.normal, state.ffnormal) > 0.0)
            absorption = vec3(0.0);

        radiance += state.mat.emission * throughput;

#ifdef LIGHTS
        if (state.isEmitter)
        {
            radiance += EmitterSample(r, state, lightSampleRec, bsdfSampleRec) * throughput;
            break;
        }
#endif

        throughput *= exp(-absorption * t);

        radiance += DirectLight(r, state) * throughput;
        
        DisneySample(state, bsdfSampleRec);

        // Set absorption only if the ray is currently inside the object.
        if (dot(state.ffnormal, bsdfSampleRec.L) < 0.0)
            absorption = -log(state.mat.extinction);

        if (bsdfSampleRec.pdf > 0.0)
            throughput *= bsdfSampleRec.f * abs(dot(state.ffnormal, bsdfSampleRec.L)) / bsdfSampleRec.pdf;
        else
            break;

#ifdef RR
        // Russian roulette
        if (depth >= RR_DEPTH)
        {
            float q = min(max(throughput.x, max(throughput.y, throughput.z)) * state.eta * state.eta + 0.001, 0.95);
            if (rand() > q)
                break;
            throughput /= q;
        }
#endif

        r.direction = bsdfSampleRec.L;
        r.origin = state.fhp + r.direction * EPS;
    }

    return radiance;
}