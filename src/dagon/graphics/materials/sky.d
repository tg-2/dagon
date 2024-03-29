/*
Copyright (c) 2017-2018 Timur Gafarov

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

module dagon.graphics.materials.sky;

import std.stdio;
import std.math;
import std.conv;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.image.color;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

/*
 * Backend for skydome material.
 */

class SkyBackend: GLSLMaterialBackend
{
    private string vsText = "
        #version 330 core
        precision highp float;

        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;

        uniform mat4 modelViewMatrix;
        uniform mat4 normalMatrix;
        uniform mat4 projectionMatrix;
        uniform mat4 invViewMatrix;

        uniform mat4 prevModelViewProjMatrix;
        uniform mat4 blurModelViewProjMatrix;

        out vec3 eyePosition;

        out vec3 worldNormal;

        out vec4 blurPosition;
        out vec4 prevPosition;

        void main()
        {
            vec4 pos = modelViewMatrix * vec4(va_Vertex, 1.0);
            eyePosition = pos.xyz;

            worldNormal = va_Normal;

            blurPosition = blurModelViewProjMatrix * vec4(va_Vertex, 1.0);
            prevPosition = prevModelViewProjMatrix * vec4(va_Vertex, 1.0);

            gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex, 1.0);
        }
    ";

    private string fsText = "
        #version 330 core
        precision highp float;

        #define EPSILON 0.000001
        #define PI 3.14159265
        const float PI2 = PI * 2.0;

        uniform vec3 sunDirection;
        uniform vec3 skyZenithColor;
        uniform vec3 skyHorizonColor;
        uniform vec3 sunColor;

        in vec3 eyePosition;
        in vec3 worldNormal;

        in vec4 blurPosition;
        in vec4 prevPosition;

        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_luma;

        uniform vec3 groundColor;
        uniform float skyEnergy;
        uniform float groundEnergy;
        uniform float sunEnergy;

        uniform sampler2D environmentMap;
        uniform bool useEnvironmentMap;

        uniform bool showSun;
        uniform bool showSunHalo;
        uniform float sunSize;
        uniform float sunScattering;

        float distributionGGX(vec3 N, vec3 H, float roughness)
        {
            float a = roughness * roughness;
            float a2 = a * a;
            float NdotH = max(dot(N, H), 0.0);
            float NdotH2 = NdotH * NdotH;
            float num = a2;
            float denom = max(NdotH2 * (a2 - 1.0) + 1.0, 0.001);
            denom = PI * denom * denom;
            return num / denom;
        }

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

        float luminance(vec3 color)
        {
            return (
                color.x * 0.27 +
                color.y * 0.67 +
                color.z * 0.06
            );
        }

        void main()
        {
            vec3 normalWorldN = normalize(worldNormal);
            vec3 env;

            vec2 posScreen = (blurPosition.xy / blurPosition.w) * 0.5 + 0.5;
            vec2 prevPosScreen = (prevPosition.xy / prevPosition.w) * 0.5 + 0.5;
            vec2 screenVelocity = posScreen - prevPosScreen;

            if (useEnvironmentMap)
            {
                env = texture(environmentMap, envMapEquirect(-normalWorldN)).rgb;
            }
            else
            {
                float horizonOrZenith = pow(clamp(dot(-normalWorldN, vec3(0, 1, 0)), 0.0, 1.0), 0.5);
                float groundOrSky = pow(clamp(dot(-normalWorldN, vec3(0, -1, 0)), 0.0, 1.0), 0.4);

                env = mix(mix(skyHorizonColor * skyEnergy, groundColor * groundEnergy, groundOrSky), skyZenithColor * skyEnergy, horizonOrZenith);
                float sun = clamp(dot(-normalWorldN, sunDirection), 0.0, 1.0);
                vec3 H = normalize(-normalWorldN + sunDirection);
                float halo = distributionGGX(-normalWorldN, H, sunScattering);
                sun = min(float(sun > (1.0 - sunSize * 0.001)) + halo, 1.0);
                env += sunColor * sun * sunEnergy;
            }

            frag_color = vec4(env, 1.0);
            frag_luma = vec4(luminance(env));
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;

    GLint prevModelViewProjMatrixLoc;
    GLint blurModelViewProjMatrixLoc;

    GLint locInvViewMatrix;
    GLint locSunDirection;
    GLint locSkyZenithColor;
    GLint locSkyHorizonColor;
    GLint locSkyEnergy;
    GLint locSunColor;
    GLint locSunEnergy;
    GLint locGroundColor;
    GLint locGroundEnergy;

    GLint environmentMapLoc;
    GLint useEnvironmentMapLoc;

    bool useEnvironmentMap = true;

    GLint showSunLoc;
    GLint showSunHaloLoc;
    GLint sunSizeLoc;
    GLint sunScatteringLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");

        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        blurModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "blurModelViewProjMatrix");

        locInvViewMatrix = glGetUniformLocation(shaderProgram, "invViewMatrix");
        locSunDirection = glGetUniformLocation(shaderProgram, "sunDirection");
        locSkyZenithColor = glGetUniformLocation(shaderProgram, "skyZenithColor");
        locSkyHorizonColor = glGetUniformLocation(shaderProgram, "skyHorizonColor");
        locSkyEnergy = glGetUniformLocation(shaderProgram, "skyEnergy");
        locSunColor = glGetUniformLocation(shaderProgram, "sunColor");
        locSunEnergy = glGetUniformLocation(shaderProgram, "sunEnergy");
        locGroundColor = glGetUniformLocation(shaderProgram, "groundColor");
        locGroundEnergy = glGetUniformLocation(shaderProgram, "groundEnergy");

        environmentMapLoc = glGetUniformLocation(shaderProgram, "environmentMap");
        useEnvironmentMapLoc = glGetUniformLocation(shaderProgram, "useEnvironmentMap");

        showSunLoc = glGetUniformLocation(shaderProgram, "showSun");
        showSunHaloLoc = glGetUniformLocation(shaderProgram, "showSunHalo");
        sunSizeLoc = glGetUniformLocation(shaderProgram, "sunSize");
        sunScatteringLoc = glGetUniformLocation(shaderProgram, "sunScattering");
    }


    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr); // valid for rotation-translations
        //glUniformMatrix4fv(locInvViewMatrix, 1, GL_FALSE, rc.invViewMatrix.arrayof.ptr);
        assert(0,"sacSkyBackend needs an invViewMatrix");
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){
        //glUniform4fv(informationLoc, 1, information.arrayof.ptr);
        assert(0,"TODO?");
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        glUseProgram(shaderProgram);

        // Matrices
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);
        glUniformMatrix4fv(locInvViewMatrix, 1, GL_FALSE, rc.invViewMatrix.arrayof.ptr);

        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, GL_FALSE, rc.prevModelViewProjMatrix.arrayof.ptr);
        glUniformMatrix4fv(blurModelViewProjMatrixLoc, 1, GL_FALSE, rc.blurModelViewProjMatrix.arrayof.ptr);

        // Environment
        Vector3f sunVector = Vector4f(rc.environment.sunDirection);
        glUniform3fv(locSunDirection, 1, sunVector.arrayof.ptr);
        Vector3f sunColor = rc.environment.sunColor;
        glUniform3fv(locSunColor, 1, sunColor.arrayof.ptr);
        glUniform1f(locSunEnergy, rc.environment.sunEnergy);
        glUniform3fv(locSkyZenithColor, 1, rc.environment.skyZenithColor.arrayof.ptr);
        glUniform3fv(locSkyHorizonColor, 1, rc.environment.skyHorizonColor.arrayof.ptr);
        glUniform1f(locSkyEnergy, rc.environment.skyEnergy);
        glUniform3fv(locGroundColor, 1, rc.environment.groundColor.arrayof.ptr);
        glUniform1f(locGroundEnergy, rc.environment.groundEnergy);

        // Texture 4 - environment map
        bool useEnvmap = false;
        if (rc.environment.environmentMap)
            useEnvmap = useEnvironmentMap;

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

        glUniform1i(showSunLoc, rc.environment.showSun);
        glUniform1i(showSunHaloLoc, rc.environment.showSunHalo);
        glUniform1f(sunSizeLoc, rc.environment.sunSize);
        glUniform1f(sunScatteringLoc, rc.environment.sunScattering);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
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

        glUseProgram(0);
    }
}
