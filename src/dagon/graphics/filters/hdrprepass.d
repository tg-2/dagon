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

module dagon.graphics.filters.hdrprepass;

import derelict.opengl;
import dlib.math.matrix;
import dagon.core.ownership;
import dagon.graphics.postproc;
import dagon.graphics.framebuffer;
import dagon.graphics.rc;

/*
 * HDR prepass filter applies HDR effects that should be done before motion blur:
 * - Glow
 * - DoF (TODO)
 */

class PostFilterHDRPrepass: PostFilter
{
    private string vs = "
        #version 330 core
        precision highp float;
        
        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        uniform vec2 viewSize;
        
        layout (location = 0) in vec2 va_Vertex;
        layout (location = 1) in vec2 va_Texcoord;

        out vec2 texCoord;
        
        void main()
        {
            texCoord = va_Texcoord;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex * viewSize, 0.0, 1.0);
        }
    ";

    private string fs = "
        #version 330 core
        precision highp float;
        
        #define PI 3.14159265359
        
        uniform sampler2D fbColor;
        uniform sampler2D fbBlurred;
        uniform vec2 viewSize;
        
        uniform mat4 perspectiveMatrix;
        
        uniform bool useGlow;
        uniform float glowBrightness;
        
        in vec2 texCoord;
        
        out vec4 frag_color;

        void main()
        {
            vec3 res = texture(fbColor, texCoord).rgb;

            if (useGlow)
            {
                vec3 glow = texture(fbBlurred, texCoord).rgb;
                float lum = glow.r * 0.2126 + glow.g * 0.7152 + glow.b * 0.0722;
                //TODO: make uniform
                const float minGlowLuminance = 0.01;
                const float maxGlowLuminance = 1.0;
                lum = (clamp(lum, minGlowLuminance, maxGlowLuminance) - minGlowLuminance) / (maxGlowLuminance - minGlowLuminance);
                res += glow * lum * glowBrightness;
            }
            res = max(res, 0.0);
            frag_color = vec4(res, 1.0); 
        }
    ";

    override string vertexShader()
    {
        return vs;
    }

    override string fragmentShader()
    {
        return fs;
    }
    
    GLint perspectiveMatrixLoc;
    Matrix4x4f perspectiveMatrix;
       
    GLint fbBlurredLoc;
    GLint useGlowLoc;
    GLint glowBrightnessLoc;
    bool glowEnabled = false;
    float glowBrightness = 1.0;
    GLuint blurredTexture;

    this(Framebuffer inputBuffer, Framebuffer outputBuffer, Owner o)
    {
        super(inputBuffer, outputBuffer, o);
        
        perspectiveMatrixLoc = glGetUniformLocation(shaderProgram, "perspectiveMatrix");
        fbBlurredLoc = glGetUniformLocation(shaderProgram, "fbBlurred");
        useGlowLoc = glGetUniformLocation(shaderProgram, "useGlow");
        glowBrightnessLoc = glGetUniformLocation(shaderProgram, "glowBrightness");
        
        perspectiveMatrix = Matrix4x4f.identity;
    }
    
    override void bind(RenderingContext* rc)
    {
        super.bind(rc);
        
        glUniformMatrix4fv(perspectiveMatrixLoc, 1, GL_FALSE, perspectiveMatrix.arrayof.ptr);
        
        glActiveTexture(GL_TEXTURE5);
        glBindTexture(GL_TEXTURE_2D, blurredTexture);
        glActiveTexture(GL_TEXTURE0);
        
        glUniform1i(fbBlurredLoc, 5);
        glUniform1i(useGlowLoc, glowEnabled);
        glUniform1f(glowBrightnessLoc, glowBrightness);
    }
    
    override void unbind(RenderingContext* rc)
    {        
        glActiveTexture(GL_TEXTURE5);
        glBindTexture(GL_TEXTURE_2D, 0);
        glActiveTexture(GL_TEXTURE0);
        
        super.unbind(rc);
    }
}
