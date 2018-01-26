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
    private string vsText = q{
        #version 330 core
        
        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;
        
        uniform mat4 modelViewMatrix;
        uniform mat4 normalMatrix;
        uniform mat4 projectionMatrix;
        uniform mat4 invViewMatrix;
        
        out vec3 worldNormal;
    
        void main()
        {
            worldNormal = va_Normal;
            
            gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex, 1.0);
        }
    };
    
    private string fsText = q{
        #version 330 core
        
        #define PI 3.14159265
        const float PI2 = PI * 2.0;
        
        uniform vec3 sunDirection;
        uniform vec3 skyZenithColor;
        uniform vec3 skyHorizonColor;
        uniform vec3 sunColor;
        
        in vec3 worldNormal;
        
        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_velocity;
        
        // TODO: make uniform
        const vec3 groundColor = vec3(0.06, 0.05, 0.05);
        const float sunEnergy = 100000.0;
        const float skyEnergyMidday = 5000.0;
        const float skyEnergyNight = 0.25;
        
        uniform sampler2D environmentMap;
        uniform bool useEnvironmentMap;
        
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
            vec3 normalWorldN = normalize(worldNormal);
            vec3 env;
            
            if (useEnvironmentMap)
            {
                env = texture(environmentMap, envMapEquirect(-normalWorldN)).rgb;
            }
            else
            {                
                float groundOrSky = pow(clamp(dot(-normalWorldN, vec3(0, 1, 0)), 0.0, 1.0), 0.5);
                float sunAngle = clamp(dot(sunDirection, vec3(0, 1, 0)), 0.0, 1.0);
                
                float skyEnergy = mix(skyEnergyNight, skyEnergyMidday, sunAngle);
                
                env = mix(skyHorizonColor, skyZenithColor, groundOrSky) * skyEnergy * sunAngle;
                float sun = clamp(dot(-normalWorldN, sunDirection), 0.0, 1.0);
                sun = min(float(sun > 0.9999) + pow(sun, 64.0) * 0.001, 1.0);
                env += sunColor * sun * sunEnergy;
            }
            frag_color = vec4(env, 1.0);
            frag_velocity = vec4(0.0, 0.0, 0.0, 1.0);
        }
    };
    
    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;
    
    GLint locInvViewMatrix;
    GLint locSunDirection;
    GLint locSkyZenithColor;
    GLint locSkyHorizonColor;
    GLint locSunColor;
    
    GLint environmentMapLoc;
    GLint useEnvironmentMapLoc;
    
    this(Owner o)
    {
        super(o);
        
        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");
            
        locInvViewMatrix = glGetUniformLocation(shaderProgram, "invViewMatrix");
        locSunDirection = glGetUniformLocation(shaderProgram, "sunDirection");
        locSkyZenithColor = glGetUniformLocation(shaderProgram, "skyZenithColor");
        locSkyHorizonColor = glGetUniformLocation(shaderProgram, "skyHorizonColor");
        locSunColor = glGetUniformLocation(shaderProgram, "sunColor");
        
        environmentMapLoc = glGetUniformLocation(shaderProgram, "environmentMap");
        useEnvironmentMapLoc = glGetUniformLocation(shaderProgram, "useEnvironmentMap");
    }
    
    override void bind(GenericMaterial mat, RenderingContext* rc)
    {    
        glUseProgram(shaderProgram);
        
        // Matrices
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);
        glUniformMatrix4fv(locInvViewMatrix, 1, GL_FALSE, rc.invViewMatrix.arrayof.ptr);
        
        // Environment
        Vector3f sunVector = Vector4f(rc.environment.sunDirection);
        glUniform3fv(locSunDirection, 1, sunVector.arrayof.ptr);
        Vector3f sunColor = rc.environment.sunColor;
        glUniform3fv(locSunColor, 1, sunColor.arrayof.ptr);
        glUniform3fv(locSkyZenithColor, 1, rc.environment.skyZenithColor.arrayof.ptr);
        glUniform3fv(locSkyHorizonColor, 1, rc.environment.skyHorizonColor.arrayof.ptr);
        
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
