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

module dagon.logics.charactercontroller;

import std.math;
import core.time: Duration;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.utils;

import dagon.logics.entity;
import dagon.logics.controller;
import dmech;

/*
 * CharacterController implements kinematic body on top of dmech dynamics: it allows direct
 * velocity changes for a RigidBody. CharacterController is intended for generic action game
 * character movement.
 */
class CharacterController: EntityController
{
    PhysicsWorld world;
    RigidBody rbody;
    bool onGround = false;
    Vector3f direction = Vector3f(0, 0, 1);
    float speed = 0.0f;
    float jSpeed = 0.0f;
    float maxVelocityChange = 0.75f;
    float artificalGravity = 50.0f;
    Vector3f rotation;
    RigidBody floorBody;
    Vector3f floorNormal;
    bool flyMode = false;
    bool clampY = true;
    ShapeComponent sensor;
    float selfTurn = 0.0f;

    this(Entity e, PhysicsWorld world, float mass, Geometry geom)
    {
        super(e);
        this.world = world;
        rbody = world.addDynamicBody(e.position);
        rbody.bounce = 0.0f;
        rbody.friction = 1.0f;
        rbody.enableRotation = false;
        rbody.useOwnGravity = true;
        rbody.gravity = Vector3f(0.0f, -artificalGravity, 0.0f);
        rbody.raycastable = false;
        world.addShapeComponent(rbody, geom, Vector3f(0, 0, 0), mass);
        rotation = Vector3f(0, 0, 0); // TODO: get from e
    }

    ShapeComponent createSensor(Geometry geom, Vector3f point)
    {
        if (sensor is null)
            sensor = world.addSensor(rbody, geom, point);
        return sensor;
    }
    
    void enableGravity(bool mode)
    {
        flyMode = !mode;
        
        if (mode)
        {
            rbody.gravity = Vector3f(0.0f, -artificalGravity, 0.0f);
        }
        else
        {
            rbody.gravity = Vector3f(0, 0, 0);
        }
    }
    
    void logicalUpdate()
    {
        Vector3f targetVelocity = direction * speed;

        if (!flyMode)
        {
            onGround = checkOnGround();
        
            if (onGround)
                rbody.gravity = Vector3f(0.0f, -artificalGravity * 0.1f, 0.0f);
            else
                rbody.gravity = Vector3f(0.0f, -artificalGravity, 0.0f);
                
            selfTurn = 0.0f;
            if (onGround && floorBody)
            {
                Vector3f relPos = rbody.position - floorBody.position;
                Vector3f rotVel = cross(floorBody.angularVelocity, relPos);
                targetVelocity += floorBody.linearVelocity;
                if (!floorBody.dynamic)
                {
                    targetVelocity += rotVel;
                    selfTurn = -floorBody.angularVelocity.y;
                }
            }
            
            speed = 0.0f;
            jSpeed = 0.0f;
        }
        else
        {
            speed *= 0.95f;
            jSpeed *= 0.95f;
        }
        
        Vector3f velocityChange = targetVelocity - rbody.linearVelocity;
        velocityChange.x = clamp(velocityChange.x, -maxVelocityChange, maxVelocityChange);
        velocityChange.z = clamp(velocityChange.z, -maxVelocityChange, maxVelocityChange);
        
        if (clampY && !flyMode)
            velocityChange.y = 0;
        else
            velocityChange.y = clamp(velocityChange.y, -maxVelocityChange, maxVelocityChange);
            
        rbody.linearVelocity += velocityChange;
    }

    override void update(Duration dt)
    {        
        entity.position = rbody.position;
        entity.rotation = rbody.orientation; 
        entity.transformation = rbody.transformation * scaleMatrix(entity.scaling);
        entity.invTransformation = entity.transformation.inverse;
    }

    bool checkOnGround()
    {
        floorBody = null;
        CastResult cr;
        bool hit = world.raycast(rbody.position, Vector3f(0, -1, 0), 10, cr, true, true);
        if (hit)
        {
            floorBody = cr.rbody;
            floorNormal = cr.normal;
        }
    
        if (sensor)
        {
            if (sensor.numCollisions > 0)
                return true;
        }
        
        return false;
    }

    void turn(float angle)
    {
        rotation.y += angle;
    }

    void move(Vector3f direction, float spd)
    {
        this.direction = direction;
        this.speed = spd;
    }

    void jump(float height)
    {
        if (onGround || flyMode)
        {
            jSpeed = jumpSpeed(height);
            rbody.linearVelocity.y = jSpeed;
        }
    }

    float jumpSpeed(float jumpHeight)
    {
        return sqrt(2.0f * jumpHeight * artificalGravity);
    }
}
