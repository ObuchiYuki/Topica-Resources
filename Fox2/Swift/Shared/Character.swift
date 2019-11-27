/*
 Copyright (C) 2018 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 This class manages the main character, including its animations, sounds and direction.
*/

import Foundation
import SceneKit
import simd

// Returns plane / ray intersection distance from ray origin.
func planeIntersect(planeNormal: float3, planeDist: Float, rayOrigin: float3, rayDirection: float3) -> Float {
    return (planeDist - simd_dot(planeNormal, rayOrigin)) / simd_dot(planeNormal, rayDirection)
}

class Character: NSObject {
    
    static private let speedFactor: CGFloat = 2.0
    static private let stepsCount = 10

    static private let initialPosition = float3(0.1, -0.2, 0)
    
    // some constants
    static private let gravity = Float(0.004)
    static private let jumpImpulse = Float(0.1)
    static private let minAltitude = Float(-10)
    static private let collisionMargin = Float(0.04)
    static private let modelOffset = float3(0, -collisionMargin, 0)
    static private let collisionMeshBitMask = 8
    
    // Character handle
    private var characterNode: SCNNode! // top level node
    private var characterOrientation: SCNNode! // the node to rotate to orient the character
    private var model: SCNNode! // the model loaded from the character file
    
    // Physics
    private var characterCollisionShape: SCNPhysicsShape?
    private var collisionShapeOffsetFromModel = float3.zero
    private var downwardAcceleration: Float = 0
    
    // Jump
    private var controllerJump: Bool = false
    private enum JumpState {case none, pressed, jumping}
    private var jumpState: JumpState = .none
    private var groundNode: SCNNode?
    var baseAltitude: Float = 0
    private var targetAltitude: Float = 0
    
    // void playing the step sound too often
    private var lastStepFrame: Int = 0
    private var frameCounter: Int = 0
    
    // Direction
    private var previousUpdateTime: TimeInterval = 0
    private var controllerDirection = float2.zero
    
    // states
    private var attackCount: Int = 0
    private var lastHitTime: TimeInterval = 0
    
    private var shouldResetCharacterPosition = false
    
    // Particle systems
    private var jumpDustParticle: SCNParticleSystem!
    private var fireEmitter: SCNParticleSystem!
    private var smokeEmitter: SCNParticleSystem!
    private var whiteSmokeEmitter: SCNParticleSystem!
    private var spinParticle: SCNParticleSystem!
    private var spinCircleParticle: SCNParticleSystem!

    private var spinParticleAttach: SCNNode!

    private var fireEmitterBirthRate: CGFloat = 0.0
    private var smokeEmitterBirthRate: CGFloat = 0.0
    private var whiteSmokeEmitterBirthRate: CGFloat = 0.0

    // Sound effects
    private var aahSound: SCNAudioSource!
    private var ouchSound: SCNAudioSource!
    private var hitSound: SCNAudioSource!
    private var hitEnemySound: SCNAudioSource!
    private var explodeEnemySound: SCNAudioSource!
    private var catchFireSound: SCNAudioSource!
    private var jumpSound: SCNAudioSource!
    private var attackSound: SCNAudioSource!
    private var steps = [SCNAudioSource](repeating: SCNAudioSource(), count: Character.stepsCount )
    
    private(set) var offsetedMark: SCNNode?
    
    // actions
    var isJump: Bool = false
    var direction = float2()
    var physicsWorld: SCNPhysicsWorld?
    
    // MARK: - Initialization
    init(scene: SCNScene) {
        super.init()

        loadCharacter()
        loadParticles()
        loadSounds()
        loadAnimations()
    }

    private func loadCharacter() {
        /// Load character from external file
        let scene = SCNScene( named: "Art.scnassets/character/max.scn")!
        model = scene.rootNode.childNode(withName: "Max_rootNode", recursively: true)
        model.simdPosition = Character.modelOffset

        /* setup character hierarchy
         character
         |_orientationNode
         |_model
         */
        characterNode = SCNNode()
        characterNode.name = "character"
        characterNode.simdPosition = Character.initialPosition

        characterOrientation = SCNNode()
        characterNode.addChildNode(characterOrientation)
        characterOrientation.addChildNode(model)

        let collider = model.childNode(withName: "collider", recursively: true)!
        collider.physicsBody?.collisionBitMask = ([ .enemy, .trigger, .collectable ] as Bitmask).rawValue

        // Setup collision shape
        let (min, max) = model.boundingBox
        let collisionCapsuleRadius = CGFloat(max.x - min.x) * CGFloat(0.4)
        let collisionCapsuleHeight = CGFloat(max.y - min.y)

        let collisionGeometry = SCNCapsule(capRadius: collisionCapsuleRadius, height: collisionCapsuleHeight)
        characterCollisionShape = SCNPhysicsShape(geometry: collisionGeometry, options:[.collisionMargin: Character.collisionMargin])
        collisionShapeOffsetFromModel = float3(0, Float(collisionCapsuleHeight) * 0.51, 0.0)
    }

    private func loadParticles() {
        var particleScene = SCNScene( named: "Art.scnassets/character/jump_dust.scn")!
        let particleNode = particleScene.rootNode.childNode(withName: "particle", recursively: true)!
        jumpDustParticle = particleNode.particleSystems!.first!

        particleScene = SCNScene( named: "Art.scnassets/particles/burn.scn")!
        let burnParticleNode = particleScene.rootNode.childNode(withName: "particles", recursively: true)!

        let particleEmitter = SCNNode()
        characterOrientation.addChildNode(particleEmitter)

        fireEmitter = burnParticleNode.childNode(withName: "fire", recursively: true)!.particleSystems![0]
        fireEmitterBirthRate = fireEmitter.birthRate
        fireEmitter.birthRate = 0

        smokeEmitter = burnParticleNode.childNode(withName: "smoke", recursively: true)!.particleSystems![0]
        smokeEmitterBirthRate = smokeEmitter.birthRate
        smokeEmitter.birthRate = 0

        whiteSmokeEmitter = burnParticleNode.childNode(withName: "whiteSmoke", recursively: true)!.particleSystems![0]
        whiteSmokeEmitterBirthRate = whiteSmokeEmitter.birthRate
        whiteSmokeEmitter.birthRate = 0

        particleScene = SCNScene(named:"Art.scnassets/particles/particles_spin.scn")!
        spinParticle = (particleScene.rootNode.childNode(withName: "particles_spin", recursively: true)?.particleSystems?.first!)!
        spinCircleParticle = (particleScene.rootNode.childNode(withName: "particles_spin_circle", recursively: true)?.particleSystems?.first!)!

        particleEmitter.position = SCNVector3Make(0, 0.05, 0)
        particleEmitter.addParticleSystem(fireEmitter)
        particleEmitter.addParticleSystem(smokeEmitter)
        particleEmitter.addParticleSystem(whiteSmokeEmitter)

        spinParticleAttach = model.childNode(withName: "particles_spin_circle", recursively: true)
    }

    private func loadSounds() {
        aahSound = SCNAudioSource( named: "audio/aah_extinction.mp3")!
        aahSound.volume = 1.0
        aahSound.isPositional = false
        aahSound.load()

        catchFireSound = SCNAudioSource(named: "audio/panda_catch_fire.mp3")!
        catchFireSound.volume = 5.0
        catchFireSound.isPositional = false
        catchFireSound.load()

        ouchSound = SCNAudioSource(named: "audio/ouch_firehit.mp3")!
        ouchSound.volume = 2.0
        ouchSound.isPositional = false
        ouchSound.load()

        hitSound = SCNAudioSource(named: "audio/hit.mp3")!
        hitSound.volume = 2.0
        hitSound.isPositional = false
        hitSound.load()

        hitEnemySound = SCNAudioSource(named: "audio/Explosion1.m4a")!
        hitEnemySound.volume = 2.0
        hitEnemySound.isPositional = false
        hitEnemySound.load()

        explodeEnemySound = SCNAudioSource(named: "audio/Explosion2.m4a")!
        explodeEnemySound.volume = 2.0
        explodeEnemySound.isPositional = false
        explodeEnemySound.load()

        jumpSound = SCNAudioSource(named: "audio/jump.m4a")!
        jumpSound.volume = 0.2
        jumpSound.isPositional = false
        jumpSound.load()

        attackSound = SCNAudioSource(named: "audio/attack.mp3")!
        attackSound.volume = 1.0
        attackSound.isPositional = false
        attackSound.load()

        for i in 0..<Character.stepsCount {
            steps[i] = SCNAudioSource(named: "audio/Step_rock_0\(UInt32(i)).mp3")!
            steps[i].volume = 0.5
            steps[i].isPositional = false
            steps[i].load()
        }
    }

    private func loadAnimations() {
        let idleAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_idle.scn")
        model.addAnimationPlayer(idleAnimation, forKey: "idle")
        idleAnimation.play()

        let walkAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_walk.scn")
        walkAnimation.speed = Character.speedFactor
        walkAnimation.stop()

        walkAnimation.animation.animationEvents = [
            SCNAnimationEvent(keyTime: 0.1, block: { _, _, _ in self.playFootStep() }),
            SCNAnimationEvent(keyTime: 0.6, block: { _, _, _ in self.playFootStep() })
        ]
        
        model.addAnimationPlayer(walkAnimation, forKey: "walk")

        let jumpAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_jump.scn")
        jumpAnimation.animation.isRemovedOnCompletion = false
        jumpAnimation.stop()
        jumpAnimation.animation.animationEvents = [SCNAnimationEvent(keyTime: 0, block: { _, _, _ in self.playJumpSound() })]
        model.addAnimationPlayer(jumpAnimation, forKey: "jump")

        let spinAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_spin.scn")
        spinAnimation.animation.isRemovedOnCompletion = false
        spinAnimation.speed = 1.5
        spinAnimation.stop()
        spinAnimation.animation.animationEvents = [SCNAnimationEvent(keyTime: 0, block: { _, _, _ in self.playAttackSound() })]
        model!.addAnimationPlayer(spinAnimation, forKey: "spin")
    }

    var node: SCNNode! {
        return characterNode
    }
        
    func queueResetCharacterPosition() {
        shouldResetCharacterPosition = true
    }
    
    // MARK: Audio
    
    func playFootStep() {
        if groundNode != nil && isWalking { // We are in the air, no sound to play.
            // Play a random step sound.
            let randSnd: Int = Int(Float(arc4random()) / Float(RAND_MAX) * Float(Character.stepsCount))
            let stepSoundIndex: Int = min(Character.stepsCount - 1, randSnd)
            characterNode.runAction(SCNAction.playAudio( steps[stepSoundIndex], waitForCompletion: false))
        }
    }
    
    func playJumpSound() {
        characterNode!.runAction(SCNAction.playAudio(jumpSound, waitForCompletion: false))
    }
    
    func playAttackSound() {
        characterNode!.runAction(SCNAction.playAudio(attackSound, waitForCompletion: false))
    }
    
    var isBurning: Bool = false {
        didSet {
            if isBurning == oldValue {
                return
            }
            //walk faster when burning
            let oldSpeed = walkSpeed
            walkSpeed = oldSpeed
            
            if isBurning {
                model.runAction(.sequence([
                    .playAudio(catchFireSound, waitForCompletion: false),
                    .playAudio(ouchSound, waitForCompletion: false),
                    .repeatForever(.sequence([
                        .fadeOpacity(to: 0.01, duration: 0.1),
                        .fadeOpacity(to: 1.0, duration: 0.1)
                    ]))
                ]))
                whiteSmokeEmitter.birthRate = 0
                fireEmitter.birthRate = fireEmitterBirthRate
                smokeEmitter.birthRate = smokeEmitterBirthRate
            } else {
                model.removeAllAudioPlayers()
                model.removeAllActions()
                model.opacity = 1.0
                model.runAction(SCNAction.playAudio(aahSound, waitForCompletion: false))
                
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.0
                whiteSmokeEmitter.birthRate = whiteSmokeEmitterBirthRate
                fireEmitter.birthRate = 0
                smokeEmitter.birthRate = 0
                SCNTransaction.commit()
                
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 5.0
                whiteSmokeEmitter.birthRate = 0
                SCNTransaction.commit()
            }
        }
    }
    
    // MARK: - Controlling the character
    
    private var directionAngle: CGFloat = 0.0 {
        didSet {
            characterOrientation.runAction(
                SCNAction.rotateTo(x: 0.0, y: directionAngle, z: 0.0, duration: 0.1, usesShortestUnitArc:true))
        }
    }
    
    func update(atTime time: TimeInterval, with renderer: SCNSceneRenderer) {
        // frameを計測
        frameCounter += 1
        
        // リセットの必要性があるか
        if shouldResetCharacterPosition {
            shouldResetCharacterPosition = false
            resetCharacterPosition()
            return
        }
        
        /// キャラクターの速度となる
        var characterVelocity = float3.zero
        
        /// カメラの向きから現在の方向を取得
        let direction = characterDirection(withPointOfView: renderer.pointOfView)
        
        if previousUpdateTime == 0.0 {
            previousUpdateTime = time
        }
        
        /// vframeによって speedを決める
        let deltaTime = time - previousUpdateTime
        let characterSpeed = CGFloat(deltaTime) * Character.speedFactor * walkSpeed
        let virtualFrameCount = Int(deltaTime / (1 / 60.0))
        previousUpdateTime = time
        
        // move
        if !direction.allZero() {
            characterVelocity = direction * Float(characterSpeed)
            
            walkSpeed = CGFloat(simd_length(direction))
            
            // move character
            directionAngle = CGFloat(atan2f(direction.x, direction.z))
            
            isWalking = true
        } else {
            isWalking = false
        }
        
        // =========================================== //
        // Hit test
        var wPosition = characterNode.simdWorldPosition
        
        // gravity
        downwardAcceleration -= Character.gravity
        wPosition.y += downwardAcceleration
        
        /// この２変数はHitTestを行う座標を狭めるため
        let HIT_RANGE = Float(0.2)
        var p0 = wPosition ; p0.y = wPosition.y + HIT_RANGE
        var p1 = wPosition ; p1.y = wPosition.y - HIT_RANGE
        
        let options: [String: Any] = [
            SCNHitTestOption.backFaceCulling.rawValue: false,
            SCNHitTestOption.categoryBitMask.rawValue: Character.collisionMeshBitMask,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: false
        ]
        
        let hitFrom = SCNVector3(p0)
        let hitTo = SCNVector3(p1)
        let hitResult = renderer.scene!.rootNode.hitTestWithSegment(from: hitFrom, to: hitTo, options: options).first
        
        // 前回床面に触っていたかどうか
        let wasTouchingTheGroup = groundNode != nil
        groundNode = nil
        
        var touchesTheGround = false
        
        if let hit = hitResult {
            let ground = float3(hit.worldCoordinates)
            
            /// 十分に下がっていたら
            if wPosition.y <= ground.y + Character.collisionMargin {
                if downwardAcceleration < 0 {
                   downwardAcceleration = 0
                }
                groundNode = hit.node
                touchesTheGround = true
                
                //touching lava?
                isBurning = groundNode?.name == "COLL_lava"
            }
            
        } else {
            
            // キャラが落ちていたらリセット
            if wPosition.y < Character.minAltitude {
                wPosition.y = Character.minAltitude
                //reset
                queueResetCharacterPosition()
            }
        }
                
        //jump -------------------------------------------------------------
        if jumpState == .none {
            /// キー押下中`isJump`は`true`
            
            // 地面に触れていて、キーが押されている
            if isJump && touchesTheGround {
                /// 下向きの加速度を `Character.jumpImpulse` にする
                downwardAcceleration += Character.jumpImpulse
                jumpState = .pressed
                
                model.animationPlayer(forKey: "jump")?.play()
            }
        } else {
            /// 前回のフレームでjumpが開始されていたら
            if jumpState == .pressed && !isJump {
                /// stateをjumpingに
                jumpState = .jumping
            }
            
            /// 上昇中にキーを外されていたら早く戻る
            if downwardAcceleration > 0 {
                for _ in 0..<virtualFrameCount {
                    if jumpState == .jumping {
                        downwardAcceleration *= 0.2
                    }
                }
            }
            
            if touchesTheGround {
                /// 今着地したならば
                if !wasTouchingTheGroup {
                    model.animationPlayer(forKey: "jump")?.stop(withBlendOutDuration: 0.1)
                    
                    // 燃えているならdustを出す
                    if isBurning {
                        model.childNode(withName: "dustEmitter", recursively: true)?.addParticleSystem(jumpDustParticle)
                    }
                }
                
                /// 地面に触れていて、キーが押されていない = `jumpState = .none`
                if !isJump {
                    jumpState = .none
                }
            }
        }
        
        /// 着地時 + マグマの上じゃない + しばらく鳴らしてない (重複防止)
        /// = 着時の音
        if touchesTheGround && !wasTouchingTheGroup && !isBurning && lastStepFrame < frameCounter - 10 {
            // sound
            lastStepFrame = frameCounter
            characterNode.runAction(.playAudio(steps[0], waitForCompletion: false))
        }
        
        //------------------------------------------------------------------
        
        characterVelocity.y += downwardAcceleration
        
        if simd_length_squared(characterVelocity) > 1e-6 {
            let startPosition = characterNode!.presentation.simdWorldPosition + collisionShapeOffsetFromModel
            
            slideInWorld(fromPosition: startPosition, velocity: characterVelocity)
        }
    }
    
    // MARK: - Animating the character
    
    var isAttacking: Bool {
        return attackCount > 0
    }
    
    func attack() {
        attackCount += 1
        model.animationPlayer(forKey: "spin")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.attackCount -= 1
        }
        spinParticleAttach.addParticleSystem(spinCircleParticle)
    }
    
    var isWalking: Bool = false {
        didSet {
            if oldValue != isWalking {
                // Update node animation.
                if isWalking {
                    model.animationPlayer(forKey: "walk")?.play()
                } else {
                    model.animationPlayer(forKey: "walk")?.stop(withBlendOutDuration: 0.2)
                }
            }
        }
    }
    
    var walkSpeed: CGFloat = 1.0 {
        didSet {
            let burningFactor: CGFloat = isBurning ? 2: 1
            model.animationPlayer(forKey: "walk")?.speed = Character.speedFactor * walkSpeed * burningFactor
        }
    }
    
    func characterDirection(withPointOfView pointOfView: SCNNode?) -> float3 {
        let controllerDir = self.direction
        if controllerDir.allZero() {
            return float3.zero
        }
        
        var directionWorld = float3.zero
        if let pov = pointOfView {
            let p1 = pov.presentation.simdConvertPosition(float3(controllerDir.x, 0.0, controllerDir.y), to: nil)
            let p0 = pov.presentation.simdConvertPosition(float3.zero, to: nil)
            directionWorld = p1 - p0
            directionWorld.y = 0
            if simd_any(directionWorld != float3.zero) {
                let minControllerSpeedFactor = Float(0.2)
                let maxControllerSpeedFactor = Float(1.0)
                let speed = simd_length(controllerDir) * (maxControllerSpeedFactor - minControllerSpeedFactor) + minControllerSpeedFactor
                directionWorld = speed * simd_normalize(directionWorld)
            }
        }
        return directionWorld
    }
    
    func resetCharacterPosition() {
        characterNode.simdPosition = Character.initialPosition
        downwardAcceleration = 0
    }
    
    // MARK: enemy
    
    func didHitEnemy() {
        model.runAction(SCNAction.group(
            [SCNAction.playAudio(hitEnemySound, waitForCompletion: false),
             SCNAction.sequence(
                [SCNAction.wait(duration: 0.5),
                 SCNAction.playAudio(explodeEnemySound, waitForCompletion: false)
                ])
            ]))
    }
    
    func wasTouchedByEnemy() {
        let time = CFAbsoluteTimeGetCurrent()
        if time > lastHitTime + 1 {
            lastHitTime = time
            model.runAction(SCNAction.sequence([
                SCNAction.playAudio(hitSound, waitForCompletion: false),
                SCNAction.repeat(SCNAction.sequence([
                    SCNAction.fadeOpacity(to: 0.01, duration: 0.1),
                    SCNAction.fadeOpacity(to: 1.0, duration: 0.1)
                    ]), count: 4)
                ]))
        }
    }
    
    // MARK: utils
    
    class func loadAnimation(fromSceneNamed sceneName: String) -> SCNAnimationPlayer {
        let scene = SCNScene( named: sceneName )!
        // find top level animation
        var animationPlayer: SCNAnimationPlayer! = nil
        scene.rootNode.enumerateChildNodes { (child, stop) in
            if !child.animationKeys.isEmpty {
                animationPlayer = child.animationPlayer(forKey: child.animationKeys[0])
                stop.pointee = true
            }
        }
        return animationPlayer
    }
    
    // MARK: - physics contact
    /// 壁の判定を行なって存在すればそれ以上進めないようにする
    func slideInWorld(fromPosition start: float3, velocity: float3) {
        // ここで何やっているのか?
        
        /// 繰り返し上限
        let maxSlideIteration: Int = 4
        
        /// 現在の繰り返し数
        var iteration = 0
        
        /// breakフラグ
        var stop: Bool = false

        /// 位置変更後の値
        var replacementPoint = start

        /// start は start
        var start = start
        
        /// 速度は速度
        var velocity = velocity
        
        let options: [SCNPhysicsWorld.TestOption: Any] = [
            .collisionBitMask: Bitmask.collision.rawValue,  /// 地面との衝突検知
            .searchMode: SCNPhysicsWorld.TestSearchMode.closest /// 最も近いものを検知
        ]

        /// 繰り返すことの
        while !stop {
            var from = matrix_identity_float4x4
            from.position = start

            var to: matrix_float4x4 = matrix_identity_float4x4
            to.position = start + velocity
            
            let contacts = physicsWorld!.convexSweepTest(
                with: characterCollisionShape!,
                from: SCNMatrix4(from),
                to: SCNMatrix4(to),
                options: options
            )
            
            /// 何か（壁）にぶつかったら
            if !contacts.isEmpty {
                /// `velocity, start` を作り直す
                (velocity, start) = handleSlidingAtContact(contacts.first!, position: start, velocity: velocity)
                iteration += 1

                /// `iteration >= maxSlideIteration`がないと変なところにハマった時に固まる

                /// 調整後の`velocity`が0または
                /// いくら(4回)調整しても治らなかったら、現在位置から動かない
                if simd_length_squared(velocity) <= 0 || iteration >= maxSlideIteration {
                    replacementPoint = start
                    stop = true
                }
            } else {
                /// ぶつからなかったらそのまま進む
                replacementPoint = start + velocity
                stop = true
            }
        }
        
        characterNode!.simdWorldPosition = replacementPoint - collisionShapeOffsetFromModel
    }

    /// 移動のstart位置と速度を作り直す
    /// ちょっとの段差とか・上方向には動けるとか
    /// 中身の精査は略
    private func handleSlidingAtContact(
        _ closestContact: SCNPhysicsContact, position start: float3, velocity: float3)
        -> (computedVelocity: simd_float3, colliderPositionAtContact: simd_float3)
    {
            
        /// 最初の距離
        let originalDistance: Float = simd_length(velocity)

        /// 衝突時のcolliderの場所
        let colliderPositionAtContact = start + Float(closestContact.sweepTestFraction) * velocity

        // Compute the sliding plane.
        let slidePlaneNormal = float3(closestContact.contactNormal)
        let slidePlaneOrigin = float3(closestContact.contactPoint)
        let centerOffset = slidePlaneOrigin - colliderPositionAtContact

        // Compute destination relative to the point of contact.
        let destinationPoint = slidePlaneOrigin + velocity

        // We now project the destination point onto the sliding plane.
        let distPlane = simd_dot(slidePlaneOrigin, slidePlaneNormal)

        // Project on plane.
        var t = planeIntersect(planeNormal: slidePlaneNormal, planeDist: distPlane,
                               rayOrigin: destinationPoint, rayDirection: slidePlaneNormal)

        let normalizedVelocity = velocity * (1.0 / originalDistance)
        let angle = simd_dot(slidePlaneNormal, normalizedVelocity)

        var frictionCoeff: Float = 0.3
        if abs(angle) < 0.9 {
            t += 10E-3
            frictionCoeff = 1.0
        }
        let newDestinationPoint = (destinationPoint + t * slidePlaneNormal) - centerOffset

        // Advance start position to nearest point without collision.
        let computedVelocity = frictionCoeff * Float(1.0 - closestContact.sweepTestFraction)
            * originalDistance * simd_normalize(newDestinationPoint - start)

        return (computedVelocity, colliderPositionAtContact)
    }

}


extension simd_float4x4: CustomStringConvertible {
    public var description: String {
        func u(_ k: simd_float4) -> String { "|\(k.x), \(k.y), \(k.z), \(k.w)|\n" }

        return u(columns.0) + u(columns.1) + u(columns.2) + u(columns.3)
    }
}
