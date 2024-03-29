﻿/*
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

module dagon.graphics.fpcamera;

import core.time: Duration;

import derelict.opengl.gl;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.utils;

import dagon.core.ownership;
import dagon.logics.entity;
import dagon.logics.controller;

class FirstPersonCamera: EntityController
{
    Matrix4x4f transformation;
    Matrix4x4f weaponTransformation;
    Matrix4x4f characterMatrix;
    Matrix4x4f invTransformation;
    Vector3f position;
    Vector3f eyePosition;
    Vector3f weaponPosition;

    float turn = 0.0f;
    float pitch = 0.0f;
    float roll = 0.0f;
    
    float weaponPitch = 0.0f;
    float weaponRoll = 0.0f;
    
    float weaponPitchCoef = 1.0f;
    
    this(Entity e)
    {
        super(e);
        this.position = e.position;
        eyePosition = Vector3f(0.0f, 1.0f, 0.0f);
        weaponPosition = Vector3f(0.0f, 0.0f, -1.0f);
        transformation = worldTrans();       
        invTransformation = transformation.inverse;
        weaponTransformation = transformation * translationMatrix(weaponPosition);
    }
    
    Matrix4x4f worldTrans()
    {  
        Matrix4x4f m = translationMatrix(position + eyePosition);
        m *= rotationMatrix(Axis.y, degtorad(turn));
        characterMatrix = m;
        m *= rotationMatrix(Axis.x, degtorad(pitch));
        m *= rotationMatrix(Axis.z, degtorad(roll));
        return m;
    }

    override void update(Duration dt)
    {
        transformation = worldTrans();
        invTransformation = transformation.inverse;
        
        weaponTransformation = translationMatrix(position + eyePosition);
        weaponTransformation *= rotationMatrix(Axis.y, degtorad(turn));
        weaponTransformation *= rotationMatrix(Axis.x, degtorad(weaponPitch));
        weaponTransformation *= rotationMatrix(Axis.z, degtorad(weaponRoll));
        weaponTransformation *= translationMatrix(weaponPosition);
        
        entity.transformation = transformation;
        entity.invTransformation = invTransformation;
    }

    Matrix4x4f viewMatrix()
    {
        return invTransformation;
    }
    
    Matrix4x4f invViewMatrix()
    {
        return transformation;
    }
}

