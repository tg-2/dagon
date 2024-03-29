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

module dagon.graphics.materials.minimap;

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

class MinimapMaterialBackend: GLSLMaterialBackend
{
    private string vsText =
    q{
        #version 330 core
        precision highp float;

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        layout (location = 0) in vec2 va_Vertex;
        layout (location = 1) in vec2 va_Texcoord;

        out vec2 screenPos;
        out vec2 texCoord;

        void main()
        {
            vec4 screenPos4 = modelViewMatrix * vec4(va_Vertex, 0.0, 1.0);
            gl_Position = projectionMatrix * screenPos4;
            screenPos = screenPos4.xy;
            texCoord = va_Texcoord;
        }
    };

    private string fsText = q{
        #version 330 core
        precision highp float;

        uniform sampler2D diffuseTexture;

        uniform vec2 center;
        uniform float radiusSq;

        uniform vec4 color;

        in vec2 screenPos;
        in vec2 texCoord;
        out vec4 frag_color;

        void main()
        {
            vec2 diff = screenPos-center;
            if(dot(diff,diff)>radiusSq)
                discard;
            frag_color = color*texture(diffuseTexture, texCoord);
        }
    };

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint diffuseTextureLoc;
    GLint centerLoc;
    GLint radiusSqLoc;
    GLint colorLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        centerLoc = glGetUniformLocation(shaderProgram, "center");
        radiusSqLoc = glGetUniformLocation(shaderProgram, "radiusSq");
        colorLoc = glGetUniformLocation(shaderProgram, "color");
    }

    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){
        //glUniform4fv(informationLoc, 1, information.arrayof.ptr);
        assert(0,"TODO?");
    }

    Color4f color=Vector4f(1.0f,1.0f,1.0f,1.0f);
    Vector2f center=Vector2f(460,400);
    float radius=80;

    final void bindDiffuse(Texture diffuse){
        glActiveTexture(GL_TEXTURE0);
        diffuse.bind();
        glUniform1i(diffuseTextureLoc, 0);
    }
    final void setColor(Color4f color){
        glUniform4fv(colorLoc,1,color.arrayof.ptr);
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = mat?"diffuse" in mat.inputs:null;
        glUseProgram(shaderProgram);

        // Matrices
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        // Texture 0 - diffuse texture
        if (idiffuse && idiffuse.texture is null)
        {
            Color4f color = Color4f(idiffuse.asVector4f);
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        if(idiffuse){
            glActiveTexture(GL_TEXTURE0);
            idiffuse.texture.bind();
            glUniform1i(diffuseTextureLoc, 0);
        }
        glUniform2fv(centerLoc,1,center.arrayof.ptr);
        glUniform1f(radiusSqLoc,radius*radius);
        glUniform4fv(colorLoc,1,color.arrayof.ptr);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        glUseProgram(0);
    }
}
