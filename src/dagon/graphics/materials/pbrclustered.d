/*
Copyright (c) 2017 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.graphics.materials.pbrclustered;

import std.stdio;
import std.math;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.interpolation;
import dlib.image.color;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.shadow;
import dagon.graphics.clustered;
import dagon.graphics.texture;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

class PBRClusteredBackend: GLSLMaterialBackend
{
    private string vsText = 
    q{
        #version 330 core
        
        uniform mat4 modelViewMatrix;
        uniform mat4 normalMatrix;
        uniform mat4 projectionMatrix;
        
        uniform mat4 invViewMatrix;
        
        uniform mat4 prevModelViewProjMatrix;
        uniform mat4 blurModelViewProjMatrix;
        
        uniform mat4 shadowMatrix1;
        uniform mat4 shadowMatrix2;
        uniform mat4 shadowMatrix3;
        
        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;
        layout (location = 2) in vec2 va_Texcoord;
        
        out vec4 position;
        out vec4 blurPosition;
        out vec4 prevPosition;
        
        out vec3 eyePosition;
        out vec3 eyeNormal;
        out vec2 texCoord;
        
        out vec3 worldPosition;
        out vec3 worldView;
        
        out vec4 shadowCoord1;
        out vec4 shadowCoord2;
        out vec4 shadowCoord3;
        
        const float eyeSpaceNormalShift = 0.05;
        
        void main()
        {
            texCoord = va_Texcoord;
            eyeNormal = (normalMatrix * vec4(va_Normal, 0.0)).xyz;
            vec4 pos = modelViewMatrix * vec4(va_Vertex, 1.0);
            eyePosition = pos.xyz;
            
            position = projectionMatrix * pos;
            blurPosition = blurModelViewProjMatrix * vec4(va_Vertex, 1.0);
            prevPosition = prevModelViewProjMatrix * vec4(va_Vertex, 1.0);
            
            worldPosition = (invViewMatrix * pos).xyz;

            vec3 worldCamPos = (invViewMatrix[3]).xyz;
            worldView = worldPosition - worldCamPos;
            
            vec4 posShifted = pos + vec4(eyeNormal * eyeSpaceNormalShift, 0.0);
            shadowCoord1 = shadowMatrix1 * posShifted;
            shadowCoord2 = shadowMatrix2 * posShifted;
            shadowCoord3 = shadowMatrix3 * posShifted;
            
            gl_Position = position;
        }
    };

    private string fsText =
    q{
        #version 330 core
        
        #define PI 3.14159265
        const float PI2 = PI * 2.0;
        
        uniform mat4 viewMatrix;
        uniform mat4 invViewMatrix;
        uniform sampler2D diffuseTexture;
        uniform sampler2D normalTexture;
        uniform sampler2D emissionTexture;
        
        uniform float roughness;
        uniform float metallic;
        
        uniform int parallaxMethod;
        uniform float parallaxScale;
        uniform float parallaxBias;
        
        uniform sampler2DArrayShadow shadowTextureArray;
        uniform float shadowTextureSize;
        uniform bool useShadows;
        
        uniform sampler2D environmentMap;
        uniform bool useEnvironmentMap;
        
        uniform vec4 environmentColor;
        uniform vec3 sunDirection;
        uniform vec3 sunColor;
        uniform float sunEnergy;
        uniform vec4 fogColor;
        uniform float fogStart;
        uniform float fogEnd;
        
        uniform vec3 skyZenithColor;
        uniform vec3 skyHorizonColor;
        
        uniform float invLightDomainSize;
        uniform usampler2D lightClusterTexture;
        uniform usampler1D lightIndexTexture;
        uniform sampler2D lightsTexture;
        
        uniform float blurMask;
        
        in vec3 eyePosition;
        
        in vec4 position;
        in vec4 blurPosition;
        in vec4 prevPosition;
        
        in vec3 eyeNormal;
        in vec2 texCoord;
        
        in vec3 worldPosition;
        in vec3 worldView;
        
        in vec4 shadowCoord1;
        in vec4 shadowCoord2;
        in vec4 shadowCoord3;
        
        //out vec4 frag_color;
        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_velocity;
        
        mat3 cotangentFrame(in vec3 N, in vec3 p, in vec2 uv)
        {
            vec3 dp1 = dFdx(p);
            vec3 dp2 = dFdy(p);
            vec2 duv1 = dFdx(uv);
            vec2 duv2 = dFdy(uv);
            vec3 dp2perp = cross(dp2, N);
            vec3 dp1perp = cross(N, dp1);
            vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
            vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
            float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
            return mat3(T * invmax, B * invmax, N);
        }
        
        vec2 parallaxMapping(in vec3 V, in vec2 T, in float scale)
        {
            float height = texture(normalTexture, T).a;
            height = height * parallaxScale + parallaxBias;
            return T + (height * V.xy);
        }
        
        // Based on code written by Igor Dykhta (Sun and Black Cat)
        // http://sunandblackcat.com/tipFullView.php?topicid=28
        vec2 parallaxOcclusionMapping(in vec3 V, in vec2 T, in float scale)
        {
            const float minLayers = 10;
            const float maxLayers = 15;
            float numLayers = mix(maxLayers, minLayers, abs(dot(vec3(0, 0, 1), V)));

            float layerHeight = 1.0 / numLayers;
            float curLayerHeight = 0;
            vec2 dtex = scale * V.xy / V.z / numLayers;

            vec2 currentTextureCoords = T;
            float heightFromTexture = texture(normalTexture, currentTextureCoords).a;

            while(heightFromTexture > curLayerHeight)
            {
                curLayerHeight += layerHeight;
                currentTextureCoords += dtex;
                heightFromTexture = texture(normalTexture, currentTextureCoords).a;
            }

            vec2 prevTCoords = currentTextureCoords - dtex;

            float nextH = heightFromTexture - curLayerHeight;
            float prevH = texture(normalTexture, prevTCoords).a - curLayerHeight + layerHeight;
            float weight = nextH / (nextH - prevH);
            return prevTCoords * weight + currentTextureCoords * (1.0-weight);
        }
        
        float shadowLookup(in sampler2DArrayShadow depths, in float layer, in vec4 coord, in vec2 offset)
        {
            float texelSize = 1.0 / shadowTextureSize;
            vec2 v = offset * texelSize * coord.w;
            vec4 c = (coord + vec4(v.x, v.y, 0.0, 0.0)) / coord.w;
            c.w = c.z;
            c.z = layer;
            float s = texture(depths, c);
            return s;
        }
        
        float pcf(in sampler2DArrayShadow depths, in float layer, in vec4 coord, in float radius, in float yshift)
        {
            float s = 0.0;
            float x, y;
	        for (y = -radius ; y < radius ; y += 1.0)
	        for (x = -radius ; x < radius ; x += 1.0)
            {
	            s += shadowLookup(depths, layer, coord, vec2(x, y + yshift));
            }
	        s /= radius * radius * 4.0;
            return s;
        }
        
        float weight(in vec4 tc, in float coef)
        {
            vec2 proj = vec2(tc.x / tc.w, tc.y / tc.w);
            proj = (1.0 - abs(proj * 2.0 - 1.0)) * coef;
            proj = clamp(proj, 0.0, 1.0);
            return min(proj.x, proj.y);
        }
        
        vec3 linePlaneIntersect(in vec3 lp, in vec3 lv, in vec3 pc, in vec3 pn)
        {
            return lp+lv*(dot(pn,pc-lp)/dot(pn,lv));
        }
        
        void sphericalAreaLightContrib(
            in vec3 P, in vec3 N, in vec3 E, in vec3 R,
            in vec3 lPos, in float lRadius,
            in float shininess,
            out float diff, out float spec)
        {
            vec3 positionToLightSource = lPos - P;
	        vec3 centerToRay = dot(positionToLightSource, R) * R - positionToLightSource;
	        vec3 closestPoint = positionToLightSource + centerToRay * clamp(lRadius / length(centerToRay), 0.0, 1.0);	
	        vec3 L = normalize(closestPoint);
            float NH = dot(N, normalize(L + E));
            spec = pow(max(NH, 0.0), shininess);
            vec3 directionToLight = normalize(positionToLightSource);
            diff = clamp(dot(N, directionToLight), 0.0, 1.0);
        }
        
        // TODO: pass this as parameter
        const vec3 groundColor = vec3(0.06, 0.05, 0.05);
        const float skyEnergyMidday = 5000.0;
        const float skyEnergyNight = 0.25;
        
        vec2 envMapEquirect(vec3 dir)
        {
            float phi = acos(dir.y);
            float theta = atan(dir.x, dir.z) + PI;
            return vec2(theta / PI2, phi / PI);
        }

        vec3 toLinear(vec3 v)
        {
            return pow(v, vec3(2.2));
        }
        
        void main()
        {     
            // Common vectors
            vec3 N = normalize(eyeNormal);
            vec3 E = normalize(-eyePosition);
            mat3 TBN = cotangentFrame(N, eyePosition, texCoord);
            vec3 tE = normalize(E * TBN);
            
            vec3 cameraPosition = invViewMatrix[3].xyz;
            
            vec2 posScreen = (blurPosition.xy / blurPosition.w) * 0.5 + 0.5;
            vec2 prevPosScreen = (prevPosition.xy / prevPosition.w) * 0.5 + 0.5;
            vec2 screenVelocity = posScreen - prevPosScreen;

            // Parallax mapping
            vec2 shiftedTexCoord = texCoord;
            if (parallaxMethod == 0)
                shiftedTexCoord = texCoord;
            else if (parallaxMethod == 1)
                shiftedTexCoord = parallaxMapping(tE, texCoord, parallaxScale);
            else if (parallaxMethod == 2)
                shiftedTexCoord = parallaxOcclusionMapping(tE, texCoord, parallaxScale);
            
            // Normal mapping
            vec3 tN = normalize(texture(normalTexture, shiftedTexCoord).rgb * 2.0 - 1.0);
            tN.y = -tN.y;
            N = normalize(TBN * tN);

            // Roughness to blinn-phong specular power
            float gloss = max(1.0 - roughness, 0.0001);
            float shininess = gloss * 128.0;
            
            // Calculate shadow from 3 cascades
            float s1, s2, s3;
            if (useShadows)
            {
                s1 = pcf(shadowTextureArray, 0.0, shadowCoord1, 2.0, 0.0);
                s2 = pcf(shadowTextureArray, 1.0, shadowCoord2, 1.0, 0.0);
                s3 = pcf(shadowTextureArray, 2.0, shadowCoord3, 1.0, 0.0);
                float w1 = weight(shadowCoord1, 8.0);
                float w2 = weight(shadowCoord2, 8.0);
                float w3 = weight(shadowCoord3, 8.0);
                s3 = mix(1.0, s3, w3); 
                s2 = mix(s3, s2, w2);
                s1 = mix(s2, s1, w1); // s1 stores resulting shadow value
            }
            else
            {
                s1 = 1.0f;
            }
            
            vec3 R = reflect(E, N);
            
            vec3 worldN = N * mat3(viewMatrix);
            vec3 worldR = reflect(normalize(worldView), worldN);
            vec3 worldSun = sunDirection * mat3(viewMatrix);
            
            // Fetch light cluster slice
            vec2 clusterCoord = (worldPosition.xz - cameraPosition.xz) * invLightDomainSize + 0.5;
            uint clusterIndex = texture(lightClusterTexture, clusterCoord).r;
            uint offset = (clusterIndex << 16) >> 16;
            uint size = (clusterIndex >> 16);
            
            vec3 pointDiffSum = vec3(0.0, 0.0, 0.0);
            vec3 pointSpecSum = vec3(0.0, 0.0, 0.0);
            for (uint i = 0u; i < size; i++)
            {
                // Read light data
                uint u = texelFetch(lightIndexTexture, int(offset + i), 0).r;
                vec3 lightPos = texelFetch(lightsTexture, ivec2(u, 0), 0).xyz; 
                vec3 lightColor = toLinear(texelFetch(lightsTexture, ivec2(u, 1), 0).xyz); 
                vec3 lightProps = texelFetch(lightsTexture, ivec2(u, 2), 0).xyz;
                float lightRadius = lightProps.x;
                float lightAreaRadius = lightProps.y;
                float lightEnergy = lightProps.z;
                
                vec3 lightPosEye = (viewMatrix * vec4(lightPos, 1.0)).xyz;
                
                vec3 positionToLightSource = lightPosEye - eyePosition;
                float distanceToLight = length(positionToLightSource);
                vec3 directionToLight = normalize(positionToLightSource);                
                float attenuation = clamp(1.0 - (distanceToLight / lightRadius), 0.0, 1.0) * lightEnergy;
                
                float diff = 0.0;
                float spec = 0.0;

                sphericalAreaLightContrib(eyePosition, N, E, R, lightPosEye, lightAreaRadius, shininess, diff, spec);

                pointDiffSum += lightColor * diff * attenuation;
                pointSpecSum += lightColor * spec * attenuation;
            }
            
            // Fog
            float fogDistance = gl_FragCoord.z / gl_FragCoord.w;
            float fogFactor = clamp((fogEnd - fogDistance) / (fogEnd - fogStart), 0.0, 1.0);
            
            // Diffuse texture
            vec4 diffuseColor = texture(diffuseTexture, shiftedTexCoord);
            vec3 albedo = toLinear(diffuseColor.rgb);
            
            vec3 emissionColor = texture(emissionTexture, shiftedTexCoord).rgb;

            vec3 envDiff;
            vec3 envSpec;
            
            const float shadowBrightness = 0.01; // TODO: make uniform
            
            if (useEnvironmentMap)
            {
                ivec2 envMapSize = textureSize(environmentMap, 0);
                float maxLod = log2(float(max(envMapSize.x, envMapSize.y)));
                float diffLod = (maxLod - 1.0);
                float specLod = (maxLod - 1.0) * roughness;
                
                envDiff = textureLod(environmentMap, envMapEquirect(worldN), diffLod).rgb;
                envSpec = textureLod(environmentMap, envMapEquirect(worldR), specLod).rgb;
                
                float sunDiff = max(0.0, dot(sunDirection, N));
                
                envDiff *= max(s1 * sunDiff, shadowBrightness);
                envSpec *= max(s1 * sunDiff, shadowBrightness);
            }
            else
            {
                float sunDiff = max(0.0, dot(sunDirection, N));
                float NH = clamp(dot(N, normalize(sunDirection + E)), 0.0, 1.0);

                float groundOrSky = pow(clamp(dot(worldN, vec3(0, 1, 0)), 0.0, 1.0), 0.5);
                float sunAngle = clamp(dot(worldSun, vec3(0, 1, 0)), 0.0, 1.0);
                
                float skyEnergy = mix(skyEnergyNight, skyEnergyMidday, sunAngle);
                
                vec3 env = mix(groundColor * sunColor * sunAngle * sunEnergy, skyZenithColor * skyEnergy, groundOrSky);
                
                float disk = mix(float(NH > 0.9999), pow(NH, 1024.0), roughness);
                float haze = pow(NH, mix(64.0, 8.0, roughness)) * mix(0.001, 0.0001, roughness);
                
                float sunSpec = min(1.0, disk + haze);

                envDiff = env + sunColor * sunEnergy * sunDiff * s1;
                envSpec = env + sunColor * sunEnergy * sunSpec * s1;
            }
            
            vec3 diffLight = envDiff + pointDiffSum;
            vec3 specLight = envSpec + pointSpecSum;

            vec3 diffColor = albedo - albedo * metallic;
            vec3 specColor = mix(vec3(1.0), albedo, metallic);

            float fresnel = pow(1.0 - max(0.0, dot(N, E)), 5.0); 
            
            vec3 roughDielectric = mix(diffColor * diffLight, specLight * gloss, 0.04);
            vec3 shinyDielectric = mix(roughDielectric, specLight, gloss);
            vec3 dielectric = mix(roughDielectric, shinyDielectric, fresnel);
            vec3 metal = mix(specColor * specLight, specLight, fresnel);
            
            vec3 objColor = emissionColor + mix(dielectric, metal, metallic);
                
            vec3 fragColor = mix(fogColor.rgb, objColor, fogFactor);
            float alpha = mix(diffuseColor.a, 1.0f, fresnel);
            
            frag_color = vec4(objColor, alpha);
            
            frag_velocity = vec4(screenVelocity, 0.0, blurMask);
        }
    };
    
    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint viewMatrixLoc;
    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;
    GLint invViewMatrixLoc;
    
    GLint prevModelViewProjMatrixLoc;
    GLint blurModelViewProjMatrixLoc;
    
    GLint shadowMatrix1Loc;
    GLint shadowMatrix2Loc; 
    GLint shadowMatrix3Loc;
    GLint shadowTextureArrayLoc;
    GLint shadowTextureSizeLoc;
    GLint useShadowsLoc;
    
    GLint roughnessLoc;
    GLint metallicLoc;
    
    GLint parallaxMethodLoc;
    GLint parallaxScaleLoc;
    GLint parallaxBiasLoc;
    
    GLint diffuseTextureLoc;
    GLint normalTextureLoc;
    GLint emissionTextureLoc;
    
    GLint environmentMapLoc;
    GLint useEnvironmentMapLoc;
    
    GLint environmentColorLoc;
    GLint sunDirectionLoc;
    GLint sunColorLoc;
    GLint sunEnergyLoc;
    GLint fogStartLoc;
    GLint fogEndLoc;
    GLint fogColorLoc;
    
    GLint skyZenithColorLoc;
    GLint skyHorizonColorLoc;
    
    GLint invLightDomainSizeLoc;
    GLint clusterTextureLoc;
    GLint lightsTextureLoc;
    GLint indexTextureLoc;
    
    GLint blurMaskLoc;
    
    ClusteredLightManager lightManager;
    CascadedShadowMap shadowMap;
    Matrix4x4f defaultShadowMat;
    Vector3f defaultLightDir;
    
    this(ClusteredLightManager clm, Owner o)
    {
        super(o);
        
        lightManager = clm;

        viewMatrixLoc = glGetUniformLocation(shaderProgram, "viewMatrix");
        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");
        invViewMatrixLoc = glGetUniformLocation(shaderProgram, "invViewMatrix");
        
        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        blurModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "blurModelViewProjMatrix");
        
        shadowMatrix1Loc = glGetUniformLocation(shaderProgram, "shadowMatrix1");
        shadowMatrix2Loc = glGetUniformLocation(shaderProgram, "shadowMatrix2");
        shadowMatrix3Loc = glGetUniformLocation(shaderProgram, "shadowMatrix3");
        shadowTextureArrayLoc = glGetUniformLocation(shaderProgram, "shadowTextureArray");
        shadowTextureSizeLoc = glGetUniformLocation(shaderProgram, "shadowTextureSize");
        useShadowsLoc = glGetUniformLocation(shaderProgram, "useShadows");
        
        roughnessLoc = glGetUniformLocation(shaderProgram, "roughness"); 
        metallicLoc = glGetUniformLocation(shaderProgram, "metallic"); 
       
        parallaxMethodLoc = glGetUniformLocation(shaderProgram, "parallaxMethod");
        parallaxScaleLoc = glGetUniformLocation(shaderProgram, "parallaxScale");
        parallaxBiasLoc = glGetUniformLocation(shaderProgram, "parallaxBias");
        
        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        normalTextureLoc = glGetUniformLocation(shaderProgram, "normalTexture");
        emissionTextureLoc = glGetUniformLocation(shaderProgram, "emissionTexture");
        
        environmentMapLoc = glGetUniformLocation(shaderProgram, "environmentMap");
        useEnvironmentMapLoc = glGetUniformLocation(shaderProgram, "useEnvironmentMap");
        
        environmentColorLoc = glGetUniformLocation(shaderProgram, "environmentColor");
        sunDirectionLoc = glGetUniformLocation(shaderProgram, "sunDirection");
        sunColorLoc = glGetUniformLocation(shaderProgram, "sunColor");
        sunEnergyLoc = glGetUniformLocation(shaderProgram, "sunEnergy");
        fogStartLoc = glGetUniformLocation(shaderProgram, "fogStart");
        fogEndLoc = glGetUniformLocation(shaderProgram, "fogEnd");
        fogColorLoc = glGetUniformLocation(shaderProgram, "fogColor");
        
        skyZenithColorLoc = glGetUniformLocation(shaderProgram, "skyZenithColor");
        skyHorizonColorLoc = glGetUniformLocation(shaderProgram, "skyHorizonColor");
        
        clusterTextureLoc = glGetUniformLocation(shaderProgram, "lightClusterTexture");
        invLightDomainSizeLoc = glGetUniformLocation(shaderProgram, "invLightDomainSize");
        lightsTextureLoc = glGetUniformLocation(shaderProgram, "lightsTexture");
        indexTextureLoc = glGetUniformLocation(shaderProgram, "lightIndexTexture");
        
        blurMaskLoc = glGetUniformLocation(shaderProgram, "blurMask");
    }
    
    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto iheight = "height" in mat.inputs;
        auto iemission = "emission" in mat.inputs;
        auto iroughness = "roughness" in mat.inputs;
        auto imetallic = "metallic" in mat.inputs;
        bool fogEnabled = boolProp(mat, "fogEnabled");
        bool shadowsEnabled = boolProp(mat, "shadowsEnabled");
        int parallaxMethod = intProp(mat, "parallax");
        if (parallaxMethod > ParallaxOcclusionMapping)
            parallaxMethod = ParallaxOcclusionMapping;
        if (parallaxMethod < 0)
            parallaxMethod = 0;
        
        glUseProgram(shaderProgram);
        
        glUniform1f(blurMaskLoc, rc.blurMask);
        
        // Matrices
        glUniformMatrix4fv(viewMatrixLoc, 1, GL_FALSE, rc.viewMatrix.arrayof.ptr);
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);
        glUniformMatrix4fv(invViewMatrixLoc, 1, GL_FALSE, rc.invViewMatrix.arrayof.ptr);
        
        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, GL_FALSE, rc.prevModelViewProjMatrix.arrayof.ptr);
        glUniformMatrix4fv(blurModelViewProjMatrixLoc, 1, GL_FALSE, rc.blurModelViewProjMatrix.arrayof.ptr);
        
        // Environment parameters
        Color4f environmentColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        Vector4f sunHGVector = Vector4f(0.0f, 1.0f, 0.0, 0.0f);
        Vector3f sunColor = Vector3f(1.0f, 1.0f, 1.0f);
        float sunEnergy = 100.0f;
        if (rc.environment)
        {
            environmentColor = rc.environment.ambientConstant;
            sunHGVector = Vector4f(rc.environment.sunDirection);
            sunHGVector.w = 0.0;
            sunColor = rc.environment.sunColor;
            sunEnergy = rc.environment.sunEnergy;
        }
        glUniform4fv(environmentColorLoc, 1, environmentColor.arrayof.ptr);
        Vector3f sunDirectionEye = sunHGVector * rc.viewMatrix;
        glUniform3fv(sunDirectionLoc, 1, sunDirectionEye.arrayof.ptr);
        glUniform3fv(sunColorLoc, 1, sunColor.arrayof.ptr);
        glUniform1f(sunEnergyLoc, sunEnergy);
        Color4f fogColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        float fogStart = float.max;
        float fogEnd = float.max;
        if (fogEnabled)
        {
            if (rc.environment)
            {                
                fogColor = rc.environment.fogColor;
                fogStart = rc.environment.fogStart;
                fogEnd = rc.environment.fogEnd;
            }
        }
        glUniform4fv(fogColorLoc, 1, fogColor.arrayof.ptr);
        glUniform1f(fogStartLoc, fogStart);
        glUniform1f(fogEndLoc, fogEnd);
        
        Color4f skyZenithColor = environmentColor;
        Color4f skyHorizonColor = environmentColor;
        if (rc.environment)
        {
            skyZenithColor = rc.environment.skyZenithColor;
            skyHorizonColor = rc.environment.skyHorizonColor;
        }
        glUniform3fv(skyZenithColorLoc, 1, skyZenithColor.arrayof.ptr);
        glUniform3fv(skyHorizonColorLoc, 1, skyHorizonColor.arrayof.ptr);
                
        // Texture 0 - diffuse texture
        if (idiffuse.texture is null)
        {
            Color4f color = Color4f(idiffuse.asVector4f);
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.bind();
        glUniform1i(diffuseTextureLoc, 0);
        
        // Texture 1 - normal map + parallax map
        float parallaxScale = 0.03f;
        float parallaxBias = -0.01f;
        bool normalTexturePrepared = inormal.texture !is null;
        if (normalTexturePrepared) 
            normalTexturePrepared = inormal.texture.image.channels == 4;
        if (!normalTexturePrepared)
        {
            if (inormal.texture is null)
            {
                Color4f color = Color4f(0.5f, 0.5f, 1.0f, 0.0f); // default normal pointing upwards
                inormal.texture = makeOnePixelTexture(mat, color);
            }
            else
            {
                if (iheight.texture !is null)
                    packAlphaToTexture(inormal.texture, iheight.texture);
                else
                    packAlphaToTexture(inormal.texture, 0.0f);
            }
        }
        glActiveTexture(GL_TEXTURE1);
        inormal.texture.bind();
        glUniform1i(normalTextureLoc, 1);
        glUniform1f(parallaxScaleLoc, parallaxScale);
        glUniform1f(parallaxBiasLoc, parallaxBias);
        glUniform1i(parallaxMethodLoc, parallaxMethod);
        
        // Texture 2 is reserved for PBR maps (roughness + metallic)
        glUniform1f(roughnessLoc, iroughness.asFloat);
        glUniform1f(metallicLoc, imetallic.asFloat);
        
        // Texture 3 - emission map
        if (iemission.texture is null)
        {
            Color4f color = Color4f(iemission.asVector4f);
            iemission.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE3);
        iemission.texture.bind();
        glUniform1i(emissionTextureLoc, 3);
        
        // Texture 4 - environment map
        bool useEnvmap = false;
        if (rc.environment)
        {
            if (rc.environment.environmentMap)
                useEnvmap = true;
        }
        
        if (useEnvmap)
        {
            glActiveTexture(GL_TEXTURE4);
            rc.environment.environmentMap.bind();
            glUniform1i(useEnvironmentMapLoc, 1);
        }
        else
        {
            glUniform1i(useEnvironmentMapLoc, 0);
        }
        glUniform1i(environmentMapLoc, 4);
        
        // Texture 5 - shadow map cascades (3 layer texture array)
        if (shadowMap && shadowsEnabled)
        {
            glActiveTexture(GL_TEXTURE5);
            glBindTexture(GL_TEXTURE_2D_ARRAY, shadowMap.depthTexture);

            glUniform1i(shadowTextureArrayLoc, 5);
            glUniform1f(shadowTextureSizeLoc, cast(float)shadowMap.size);
            glUniformMatrix4fv(shadowMatrix1Loc, 1, 0, shadowMap.area1.shadowMatrix.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix2Loc, 1, 0, shadowMap.area2.shadowMatrix.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix3Loc, 1, 0, shadowMap.area3.shadowMatrix.arrayof.ptr);
            glUniform1i(useShadowsLoc, 1);
            
            // TODO: shadowFilter
        }
        else
        {        
            glUniformMatrix4fv(shadowMatrix1Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix2Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix3Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniform1i(useShadowsLoc, 0);
        }

        // Texture 6 - light clusters
        glActiveTexture(GL_TEXTURE6);
        lightManager.bindClusterTexture();
        glUniform1i(clusterTextureLoc, 6);
        glUniform1f(invLightDomainSizeLoc, lightManager.invSceneSize);
        
        // Texture 7 - light data
        glActiveTexture(GL_TEXTURE7);
        lightManager.bindLightTexture();
        glUniform1i(lightsTextureLoc, 7);
        
        // Texture 8 - light indices per cluster
        glActiveTexture(GL_TEXTURE8);
        lightManager.bindIndexTexture();
        glUniform1i(indexTextureLoc, 8);
        
        glActiveTexture(GL_TEXTURE0);
    }
    
    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto iemission = "emission" in mat.inputs;
        
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();
        
        glActiveTexture(GL_TEXTURE1);
        inormal.texture.unbind();
        
        glActiveTexture(GL_TEXTURE3);
        iemission.texture.unbind();
        
        bool useEnvmap = false;
        if (rc.environment)
        {
            if (rc.environment.environmentMap)
                useEnvmap = true;
        }
        
        if (useEnvmap)
        {
            glActiveTexture(GL_TEXTURE4);
            rc.environment.environmentMap.unbind();
        }

        glActiveTexture(GL_TEXTURE5);
        glBindTexture(GL_TEXTURE_2D_ARRAY, 0);
        
        glActiveTexture(GL_TEXTURE6);
        lightManager.unbindClusterTexture();
        
        glActiveTexture(GL_TEXTURE7);
        lightManager.unbindLightTexture();
        
        glActiveTexture(GL_TEXTURE8);
        lightManager.unbindIndexTexture();
        
        glActiveTexture(GL_TEXTURE0);
        
        glUseProgram(0);
    }
}
