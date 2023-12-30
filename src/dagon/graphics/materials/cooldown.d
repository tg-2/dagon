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

module dagon.graphics.materials.cooldown;

import std.stdio;
import std.math;
import std.conv;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.image.color;
import dlib.image.unmanaged;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.texture;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

class CooldownMaterialBackend: GLSLMaterialBackend
{
    private string vsText =
    `
        #version 330 core
        precision highp float;

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;
        uniform float progress;

        layout (location = 0) in vec2 va_Vertex;
        layout (location = 1) in float index;

        #define M_PI 3.1415926535897932384626433832795

        out vec2 position;

        void main()
        {
            float alpha = 2.0f*M_PI*max(0.0, progress-0.25f*(index-1.0f));
            if(index==1.0f){ alpha=2.0f*M_PI*progress; }
            float ca = cos(alpha);
            float sa = sin(alpha);
            position = vec2(va_Vertex.x*ca-va_Vertex.y*sa, va_Vertex.x*sa+va_Vertex.y*ca);
            gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 0.0, 1.0);;
        }
    `;

    private string fsText = q{
        #version 330 core
        precision highp float;

        in vec2 position;
        out vec4 frag_color;

        void main()
        {
            float distance = 2.0*length(position);
            float alpha = (1.0-distance)+0.1*distance;
            if(16.0*distance > 15.0){ alpha = alpha*max(0.0, 1.0-(16.0*distance-15.0)); }
            frag_color = vec4(0.0,182.0/255.0,1.0,alpha); // TODO: figure out the color
        }
    };

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint progressLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        progressLoc = glGetUniformLocation(shaderProgram, "progress");
    }

    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
    }
    final void setAlpha(float alpha){ assert(0); }
    final void setInformation(Vector4f information){ assert(0); }
    final void bindDiffuse(Texture diffuse){ assert(0); }
    final void setProgress(float progress){
        glUniform1f(progressLoc, progress);
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        glUseProgram(shaderProgram);

        // Matrices
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        if(!mat){
            glEnablei(GL_BLEND, 0);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        }
        glUniform1f(progressLoc, 0.0f);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        glUseProgram(0);
    }
}
