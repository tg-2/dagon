/*
Copyright (c) 2018 Timur Gafarov

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

module dagon.graphics.gbuffer;

import std.stdio;
import std.math;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.image.color;
import derelict.opengl;
import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.material;
import dagon.graphics.materials.generic;
import dagon.resource.scene;

class GeometryPassBackend: GLSLMaterialBackend
{
    string vsText =
    "
        #version 330 core
        precision highp float;

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;
        uniform mat4 normalMatrix;

        uniform mat4 prevModelViewProjMatrix;
        uniform mat4 blurModelViewProjMatrix;

        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;
        layout (location = 2) in vec2 va_Texcoord;

        out vec2 texCoord;
        out vec3 eyePosition;
        out vec3 eyeNormal;

        out vec4 blurPosition;
        out vec4 prevPosition;

        void main()
        {
            texCoord = va_Texcoord;
            eyeNormal = (normalMatrix * vec4(va_Normal, 0.0)).xyz;
            vec4 pos = modelViewMatrix * vec4(va_Vertex, 1.0);
            eyePosition = pos.xyz;

            vec4 position = projectionMatrix * pos;

            blurPosition = blurModelViewProjMatrix * vec4(va_Vertex, 1.0);
            prevPosition = prevModelViewProjMatrix * vec4(va_Vertex, 1.0);

            gl_Position = position;
        }
    ";

    string fsText =
    "
        #version 330 core
        #extension GL_OES_standard_derivatives : enable
        precision highp float;

        uniform int layer;

        uniform sampler2D diffuseTexture;
        uniform sampler2D normalTexture;
        uniform sampler2D rmsTexture;
        uniform sampler2D emissionTexture;
        uniform float emissionEnergy;

        uniform int parallaxMethod;
        uniform float parallaxScale;
        uniform float parallaxBias;

        uniform float blurMask;

        uniform vec4 information;

        in vec2 texCoord;
        in vec3 eyePosition;
        in vec3 eyeNormal;

        in vec4 blurPosition;
        in vec4 prevPosition;

        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_rms;
        layout(location = 2) out vec4 frag_position;
        layout(location = 3) out vec4 frag_normal;
        layout(location = 4) out vec4 frag_velocity;
        layout(location = 5) out vec4 frag_emission;
        layout(location = 6) out vec4 frag_information;

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

        vec2 parallaxMapping(in vec3 V, in vec2 T, out float h)
        {
            float height = texture(normalTexture, T).a;
            h = height;
            height = height * parallaxScale + parallaxBias;
            return T + (height * V.xy);
        }

        void main()
        {
            vec3 E = normalize(-eyePosition);
            vec3 N = normalize(eyeNormal);
            mat3 TBN = cotangentFrame(N, eyePosition, texCoord);
            vec3 tE = normalize(E * TBN);

            vec2 posScreen = (blurPosition.xy / blurPosition.w) * 0.5 + 0.5;
            vec2 prevPosScreen = (prevPosition.xy / prevPosition.w) * 0.5 + 0.5;
            vec2 screenVelocity = posScreen - prevPosScreen;

            // Parallax mapping
            float height = 0.0;
            vec2 shiftedTexCoord = texCoord;
            if (parallaxMethod == 1)
                shiftedTexCoord = parallaxMapping(tE, texCoord, height);

            // Normal mapping
            vec3 tN = normalize(texture(normalTexture, shiftedTexCoord).rgb * 2.0 - 1.0);
            tN.y = -tN.y;
            N = normalize(TBN * tN);

            // Textures
            vec4 diffuseColor = texture(diffuseTexture, shiftedTexCoord);
            if (diffuseColor.a == 0.0f)
                discard;
            vec4 rms = texture(rmsTexture, shiftedTexCoord);
            vec3 emission = texture(emissionTexture, shiftedTexCoord).rgb * emissionEnergy;

            float geomMask = float(layer > 0);

            frag_color = vec4(diffuseColor.rgb, geomMask);
            frag_rms = vec4(rms.r, rms.g, 1.0, 1.0);
            frag_position = vec4(eyePosition, geomMask);
            frag_normal = vec4(N, 1.0);
            frag_velocity = vec4(screenVelocity, 0.0, blurMask);
            frag_emission = vec4(emission, 1.0);
            frag_information = information;
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint layerLoc;

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;

    GLint prevModelViewProjMatrixLoc;
    GLint blurModelViewProjMatrixLoc;

    GLint diffuseTextureLoc;
    GLint normalTextureLoc;
    GLint rmsTextureLoc;
    GLint emissionTextureLoc;
    GLint emissionEnergyLoc;

    GLint parallaxMethodLoc;
    GLint parallaxScaleLoc;
    GLint parallaxBiasLoc;

    GLint blurMaskLoc;

    GLint informationLoc;

    this(Owner o)
    {
        super(o);

        layerLoc = glGetUniformLocation(shaderProgram, "layer");

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");

        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        blurModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "blurModelViewProjMatrix");

        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        normalTextureLoc = glGetUniformLocation(shaderProgram, "normalTexture");
        rmsTextureLoc = glGetUniformLocation(shaderProgram, "rmsTexture");
        emissionTextureLoc = glGetUniformLocation(shaderProgram, "emissionTexture");
        emissionEnergyLoc = glGetUniformLocation(shaderProgram, "emissionEnergy");

        parallaxMethodLoc = glGetUniformLocation(shaderProgram, "parallaxMethod");
        parallaxScaleLoc = glGetUniformLocation(shaderProgram, "parallaxScale");
        parallaxBiasLoc = glGetUniformLocation(shaderProgram, "parallaxBias");

        blurMaskLoc = glGetUniformLocation(shaderProgram, "blurMask");

        informationLoc = glGetUniformLocation(shaderProgram, "information");
    }
    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr); // valid for rotation-translations
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){
        glUniform4fv(informationLoc, 1, information.arrayof.ptr);
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto iheight = "height" in mat.inputs;
        auto ipbr = "pbr" in mat.inputs;
        auto iroughness = "roughness" in mat.inputs;
        auto imetallic = "metallic" in mat.inputs;
        auto iemission = "emission" in mat.inputs;
        auto iEnergy = "energy" in mat.inputs;

        int parallaxMethod = intProp(mat, "parallax");
        if (parallaxMethod > ParallaxOcclusionMapping)
            parallaxMethod = ParallaxOcclusionMapping;
        if (parallaxMethod < 0)
            parallaxMethod = 0;

        glUseProgram(shaderProgram);

        glUniform1i(layerLoc, rc.layer);

        glUniform1f(blurMaskLoc, rc.blurMask);

        glUniform4fv(informationLoc, 1, rc.information.arrayof.ptr);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);

        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, GL_FALSE, rc.prevModelViewProjMatrix.arrayof.ptr);
        glUniformMatrix4fv(blurModelViewProjMatrixLoc, 1, GL_FALSE, rc.blurModelViewProjMatrix.arrayof.ptr);

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

        // Texture 2 - PBR maps (roughness + metallic)
        if (ipbr is null)
        {
            mat.setInput("pbr", 0.0f);
            ipbr = "pbr" in mat.inputs;
        }

        if (ipbr.texture is null)
        {
            ipbr.texture = makeTextureFrom(mat, *iroughness, *imetallic, materialInput(0.0f), materialInput(0.0f));
        }
        glActiveTexture(GL_TEXTURE2);
        glUniform1i(rmsTextureLoc, 2);
        ipbr.texture.bind();

        // Texture 3 - emission map
        if (iemission.texture is null)
        {
            Color4f color = Color4f(iemission.asVector4f);
            iemission.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE3);
        iemission.texture.bind();
        glUniform1i(emissionTextureLoc, 3);
        glUniform1f(emissionEnergyLoc, iEnergy.asFloat);

        glActiveTexture(GL_TEXTURE0);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto ipbr = "pbr" in mat.inputs;
        auto iemission = "emission" in mat.inputs;

        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();

        glActiveTexture(GL_TEXTURE1);
        inormal.texture.unbind();

        glActiveTexture(GL_TEXTURE2);
        ipbr.texture.unbind();

        glActiveTexture(GL_TEXTURE3);
        iemission.texture.unbind();

        glActiveTexture(GL_TEXTURE0);

        glUseProgram(0);
    }
}

class GBuffer: Owner
{
    uint width;
    uint height;

    Scene scene;
    GeometryPassBackend geometryBackend;

    GLuint fbo;
    GLuint depthTexture = 0;
    GLuint colorTexture = 0;
    GLuint rmsTexture = 0;
    GLuint positionTexture = 0;
    GLuint normalTexture = 0;
    GLuint velocityTexture = 0;
    GLuint emissionTexture = 0;
    GLuint informationTexture = 0;

    GLuint informationPBO = 0;

    this(uint w, uint h, Scene scene, Owner o)
    {
        super(o);

        width = w;
        height = h;

        this.scene = scene;

        geometryBackend = New!GeometryPassBackend(this);

        glActiveTexture(GL_TEXTURE0);

        glGenTextures(1, &depthTexture);
        glBindTexture(GL_TEXTURE_2D, depthTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &colorTexture);
        glBindTexture(GL_TEXTURE_2D, colorTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &rmsTexture);
        glBindTexture(GL_TEXTURE_2D, rmsTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB8, width, height, 0, GL_RGB, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &positionTexture);
        glBindTexture(GL_TEXTURE_2D, positionTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &normalTexture);
        glBindTexture(GL_TEXTURE_2D, normalTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB16F, width, height, 0, GL_RGB, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &velocityTexture);
        glBindTexture(GL_TEXTURE_2D, velocityTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &emissionTexture);
        glBindTexture(GL_TEXTURE_2D, emissionTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB16F, width, height, 0, GL_RGB, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenTextures(1, &informationTexture);
        glBindTexture(GL_TEXTURE_2D, informationTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, rmsTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, positionTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT3, GL_TEXTURE_2D, normalTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT4, GL_TEXTURE_2D, velocityTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT5, GL_TEXTURE_2D, emissionTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT6, GL_TEXTURE_2D, informationTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, depthTexture, 0);

        GLenum[7] bufs = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2, GL_COLOR_ATTACHMENT3, GL_COLOR_ATTACHMENT4, GL_COLOR_ATTACHMENT5, GL_COLOR_ATTACHMENT6];
        glDrawBuffers(bufs.length, bufs.ptr);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE)
            writeln(status);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        glGenBuffers(1, &informationPBO);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, informationPBO);
        glBufferData(GL_PIXEL_PACK_BUFFER, Vector4f.sizeof, null, GL_STREAM_READ);
    }

    final void startInformationDownload(int x,int y){
        glBindBuffer(GL_PIXEL_PACK_BUFFER,informationPBO);
        if(glGetTextureSubImage is null){
            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT6);
            glReadPixels(x,y,1,1,GL_RGBA,GL_FLOAT,null);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        }else glGetTextureSubImage(informationTexture,0,x,y,0,1,1,1,GL_RGBA,GL_FLOAT,Vector4f.sizeof,null);
    }
    final Vector4f getInformation(){
        glBindBuffer(GL_PIXEL_PACK_BUFFER, informationPBO);
        auto pointer=glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
        auto information=*cast(Vector4f*)pointer;
        glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        return information;
    }

    ~this()
    {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &fbo);

        if (glIsTexture(depthTexture))
            glDeleteTextures(1, &depthTexture);
        if (glIsTexture(colorTexture))
            glDeleteTextures(1, &colorTexture);
        if (glIsTexture(velocityTexture))
            glDeleteTextures(1, &velocityTexture);
        if (glIsTexture(rmsTexture))
            glDeleteTextures(1, &rmsTexture);
        if (glIsTexture(positionTexture))
            glDeleteTextures(1, &positionTexture);
        if (glIsTexture(normalTexture))
            glDeleteTextures(1, &normalTexture);
        if (glIsTexture(emissionTexture))
            glDeleteTextures(1, &emissionTexture);
        if (glIsTexture(emissionTexture))
            glDeleteTextures(1, &informationTexture);
    }

    void bind()
    {
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glEnablei(GL_BLEND, 6);
        //glBlendFunci(6, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    }

    void unbind()
    {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    void render(RenderingContext* rc)
    {
        bind();

        glViewport(0, 0, width, height);
        glScissor(0, 0, width, height);
        clear();

        glEnable(GL_DEPTH_TEST);

        auto rcLocal = *rc;

        scene.renderOpaqueEntities3D(&rcLocal);

        unbind();
    }

    void clear()
    {
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        Color4f zero = Color4f(0, 0, 0, 0);
        Color4f maxv = Color4f(0, 0, 0, 0);
        glClearBufferfv(GL_COLOR, 1, zero.arrayof.ptr);
        glClearBufferfv(GL_COLOR, 2, maxv.arrayof.ptr);
        glClearBufferfv(GL_COLOR, 3, zero.arrayof.ptr);
        glClearBufferfv(GL_COLOR, 4, zero.arrayof.ptr);
        glClearBufferfv(GL_COLOR, 5, zero.arrayof.ptr);
    }
}
