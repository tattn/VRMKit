import Foundation

// MARK: - Migration Logic for VRM 1.0 -> 0.x

public extension VRM.Meta {
    init(vrm1: VRM1.Meta) {
        self.init(
            title: vrm1.name,
            author: vrm1.authors.joined(separator: ", "), // VRM1 authors is [String]
            contactInformation: vrm1.contactInformation,
            reference: vrm1.references?.joined(separator: ", "),
            texture: vrm1.thumbnailImage,
            version: vrm1.version,
            allowedUserName: {
                // VRM1 avatarPermission -> VRM0 allowedUserName
                // VRM0 expects: OnlyAuthor / ExplicitlyLicensedPerson / Everyone
                switch vrm1.avatarPermission {
                case .onlyAuthor: return "OnlyAuthor"
                case .onlySeparatelyLicensedPerson: return "ExplicitlyLicensedPerson"
                case .everyone: return "Everyone"
                case .none: return "Everyone"
                }
            }(),
            violentUssageName: vrm1.allowExcessivelyViolentUsage == true ? "Allow" : "Disallow",
            sexualUssageName: vrm1.allowExcessivelySexualUsage == true ? "Allow" : "Disallow",
            commercialUssageName: vrm1.commercialUsage?.rawValue,
            otherPermissionUrl: vrm1.otherLicenseUrl,
            licenseName: vrm1.licenseUrl,
            otherLicenseUrl: vrm1.otherLicenseUrl
        )
    }
}

public extension VRM.Humanoid {
    init(vrm1: VRM1.Humanoid) {
        var bones: [HumanBone] = []
        
        let mirror = Mirror(reflecting: vrm1.humanBones)
        for child in mirror.children {
            guard let label = child.label,
                  let humanBone1 = child.value as? VRM1.Humanoid.HumanBones.HumanBone?,
                  let node = humanBone1?.node else { continue }
            let boneName = label
            bones.append(HumanBone(bone: boneName, node: node, useDefaultValues: true))
        }
        
        self.init(
            armStretch: 0.05, // Default/Unknown
            feetSpacing: 0,
            hasTranslationDoF: false,
            legStretch: 0.05,
            lowerArmTwist: 0.5,
            lowerLegTwist: 0.5,
            upperArmTwist: 0.5,
            upperLegTwist: 0.5,
            humanBones: bones
        )
    }
}

public extension VRM.BlendShapeMaster {
    init(vrm1: VRM1.Expressions?, gltf: BinaryGLTF) {
        guard let expressions = vrm1 else {
            self.init(blendShapeGroups: [])
            return
        }
        
        var groups: [BlendShapeGroup] = []
        let decoder = DictionaryDecoder()
        
        func addGroup(name: String, presetName: String, expression: VRM1.Expressions.Expression) {
            let binds: [VRM.BlendShapeMaster.BlendShapeGroup.Bind] = (expression.morphTargetBinds?.compactMap { (bind) -> VRM.BlendShapeMaster.BlendShapeGroup.Bind? in
                let meshIndex: Int?
                if let nodes = gltf.jsonData.nodes,
                   nodes.indices.contains(bind.node) {
                    meshIndex = nodes[bind.node].mesh
                } else if let meshes = gltf.jsonData.meshes,
                          meshes.indices.contains(bind.node) {
                    // Fallback: treat bind.node as a mesh index if nodes are unavailable.
                    meshIndex = bind.node
                } else {
                    meshIndex = nil
                }
                guard let meshIndex else { return nil }
                return VRM.BlendShapeMaster.BlendShapeGroup.Bind(
                    index: bind.index,
                    mesh: meshIndex,
                    weight: bind.weight * 100.0
                )
            }) ?? []
            
            // VRM1 materialColor/textureTransform -> VRM0 materialValues
            let colorValues: [VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind] = (expression.materialColorBinds?.compactMap { bind -> VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind? in
                guard let materials = gltf.jsonData.materials, bind.material < materials.count else { return nil }
                // VRM1 bind refers to material by index. Resolve the name from GLTF.
                let materialName = materials[bind.material].name ?? ""
                return VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind(
                    materialName: materialName,
                    propertyName: bind.type.rawValue,
                    targetValue: bind.targetValue
                )
            }) ?? []

            let textureValues: [VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind] = (expression.textureTransformBinds?.compactMap { bind -> VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind? in
                guard let materials = gltf.jsonData.materials, bind.material < materials.count else { return nil }
                let materialName = materials[bind.material].name ?? ""

                let scale = bind.scale ?? [1.0, 1.0]
                let offset = bind.offset ?? [0.0, 0.0]
                let sx = scale.count > 0 ? scale[0] : 1.0
                let sy = scale.count > 1 ? scale[1] : 1.0
                let ox = offset.count > 0 ? offset[0] : 0.0
                let oy = offset.count > 1 ? offset[1] : 0.0
                // glTF(top-left) -> Unity(bottom-left)
                let flippedOy = 1.0 - oy - sy

                return VRM.BlendShapeMaster.BlendShapeGroup.MaterialValueBind(
                    materialName: materialName,
                    propertyName: "_MainTex_ST",
                    targetValue: [sx, sy, ox, flippedOy]
                )
            }) ?? []

            let materialValues = colorValues + textureValues
            
            groups.append(BlendShapeGroup(
                binds: binds,
                materialValues: materialValues,
                name: name,
                presetName: presetName,
                _isBinary: expression.isBinary
            ))
        }
        
        // VRM1 preset expressions -> VRM0 BlendShapeGroup presetName mapping.
        let preset = expressions.preset
        addGroup(name: "Happy", presetName: "joy", expression: preset.happy)
        addGroup(name: "Angry", presetName: "angry", expression: preset.angry)
        addGroup(name: "Sad", presetName: "sorrow", expression: preset.sad)
        addGroup(name: "Relaxed", presetName: "fun", expression: preset.relaxed)
        addGroup(name: "Surprised", presetName: "unknown", expression: preset.surprised) // VRM0 doesn't have surprised

        // VRM0 presets: neutral, a, i, u, e, o, blink, joy, angry, sorrow, fun, lookup, lookdown, lookleft, lookright, blink_l, blink_r.
        addGroup(name: "A", presetName: "a", expression: preset.aa)
        addGroup(name: "I", presetName: "i", expression: preset.ih)
        addGroup(name: "U", presetName: "u", expression: preset.ou)
        addGroup(name: "E", presetName: "e", expression: preset.ee)
        addGroup(name: "O", presetName: "o", expression: preset.oh)
        addGroup(name: "Blink", presetName: "blink", expression: preset.blink)
        addGroup(name: "Blink_L", presetName: "blink_l", expression: preset.blinkLeft)
        addGroup(name: "Blink_R", presetName: "blink_r", expression: preset.blinkRight)

        addGroup(name: "LookUp", presetName: "lookup", expression: preset.lookUp)
        addGroup(name: "LookDown", presetName: "lookdown", expression: preset.lookDown)
        addGroup(name: "LookLeft", presetName: "lookleft", expression: preset.lookLeft)
        addGroup(name: "LookRight", presetName: "lookright", expression: preset.lookRight)
        addGroup(name: "Neutral", presetName: "neutral", expression: preset.neutral)

        // VRM1 custom expressions
        if let customMap = expressions.custom?.value as? [String: Any] {
            for name in customMap.keys.sorted() {
                guard let raw = customMap[name] as? [String: Any],
                      let expression = try? decoder.decode(VRM1.Expressions.Expression.self, from: raw) else {
                    continue
                }
                addGroup(name: name, presetName: "unknown", expression: expression)
            }
        }

        self.init(blendShapeGroups: groups)
    }
}

public extension VRM.FirstPerson {
    init(vrm1: VRM1.FirstPerson?, lookAt: VRM1.LookAt?) {
        // VRM 1.0 FirstPerson
        let meshAnnotations: [MeshAnnotation] = vrm1?.meshAnnotations.map {
            MeshAnnotation(firstPersonFlag: $0.type.rawValue, mesh: $0.node)
        } ?? []
        
        // LookAt
        let lookAtTypeName: LookAtType
        switch lookAt?.type {
            case .bone: lookAtTypeName = .bone
            case .expression: lookAtTypeName = .blendShape
            case .none: lookAtTypeName = .none
        }
        
        // VRM 1.0 LookAt offsetFromHeadBone
        let offset = lookAt?.offsetFromHeadBone ?? [0, 0, 0]
        let vec3 = VRM.Vector3(x: offset[0], y: offset[1], z: offset[2])
        
        self.init(
            firstPersonBone: -1, // Deprecated/Unknown in VRM1? VRM1 uses Head bone usually.
            // VRM0 expected an index. VRM1 doesn't specify explicit firstPersonBone index in FirstPerson struct.
            // It relies on Humanoid.head.
            firstPersonBoneOffset: vec3,
            meshAnnotations: meshAnnotations,
            lookAtTypeName: lookAtTypeName
        )
    }
}

public extension VRM.SecondaryAnimation {
    init(vrm1: VRM1.SpringBone?) {
        guard let sb = vrm1 else {
            self.init(boneGroups: [], colliderGroups: [])
            return
        }
        var vrm0ColliderGroups: [ColliderGroup] = []
        
        // Resolve all VRM 1.0 colliders
        if let vrm1Colliders = sb.colliders {
            // Group by node
            var collidersByNode: [Int: [ColliderGroup.Collider]] = [:]
            
            for collider in vrm1Colliders {
                let nodeIndex = collider.node
                var vrm0Collider: ColliderGroup.Collider?
                
                if let sphere = collider.shape.sphere {
                    vrm0Collider = ColliderGroup.Collider(
                        offset: VRM.Vector3(x: sphere.offset[0], y: sphere.offset[1], z: sphere.offset[2]),
                        radius: sphere.radius
                    )
                } else if let capsule = collider.shape.capsule {
                    // Approximate capsule as sphere (head)
                    vrm0Collider = ColliderGroup.Collider(
                        offset: VRM.Vector3(x: capsule.offset[0], y: capsule.offset[1], z: capsule.offset[2]),
                        radius: capsule.radius
                    )
                }
                
                if let c = vrm0Collider {
                    collidersByNode[nodeIndex, default: []].append(c)
                }
            }
            
            for (nodeIndex, colliders) in collidersByNode {
                vrm0ColliderGroups.append(ColliderGroup(node: nodeIndex, colliders: colliders))
            }
        }
        
        // Convert Springs (BoneGroups)
        var boneGroups: [BoneGroup] = []
        if let springs = sb.springs {
            for spring in springs {
                // Determine `colliderGroups` valid for this Spring.
                // These are shared for all split groups derived from this Spring.
                var referencedNodeIndices: Set<Int> = []
                if let groupIndices = spring.colliderGroups, let vrm1Groups = sb.colliderGroups {
                     for groupIdx in groupIndices {
                         if groupIdx >= 0 && groupIdx < vrm1Groups.count {
                             let group = vrm1Groups[groupIdx]
                             for colliderIdx in group.colliders {
                                 if let colliders = sb.colliders, colliderIdx >= 0 && colliderIdx < colliders.count {
                                     let collider = colliders[colliderIdx]
                                     referencedNodeIndices.insert(collider.node)
                                 }
                             }
                         }
                     }
                }
                
                // Find indices of vrm0ColliderGroups that correspond to these nodes
                let vrm0ColliderGroupIndices: [Int] = vrm0ColliderGroups.enumerated().compactMap { index, group in
                    return referencedNodeIndices.contains(group.node) ? index : nil
                }
                
                struct PhysicsParams: Equatable {
                    let dragForce: Double
                    let gravityDir: [Double]
                    let gravityPower: Double
                    let hitRadius: Double
                    let stiffness: Double
                }

                var currentJoints: [Int] = []
                var currentParams: PhysicsParams?
                
                for joint in spring.joints {
                    let params = PhysicsParams(
                        dragForce: joint.dragForce ?? 0.5,
                        gravityDir: joint.gravityDir ?? [0, -1, 0],
                        gravityPower: joint.gravityPower ?? 0,
                        hitRadius: joint.hitRadius ?? 0.02,
                        stiffness: joint.stiffness ?? 1.0
                    )
                    
                    if let current = currentParams, current == params {
                        // Same parameters, add to current group.
                        currentJoints.append(joint.node)
                    } else {
                        // Parameters changed or first joint.
                        if let current = currentParams, !currentJoints.isEmpty {
                            // Close previous group
                            boneGroups.append(BoneGroup(
                                bones: currentJoints,
                                center: spring.center ?? -1,
                                colliderGroups: vrm0ColliderGroupIndices,
                                comment: spring.name,
                                dragForce: current.dragForce,
                                gravityDir: VRM.Vector3(x: current.gravityDir[0], y: current.gravityDir[1], z: current.gravityDir[2]),
                                gravityPower: current.gravityPower,
                                hitRadius: current.hitRadius,
                                stiffiness: current.stiffness
                            ))
                        }
                        
                        // Start new group
                        currentParams = params
                        currentJoints = [joint.node]
                    }
                }
                
                // Close the last group
                if let current = currentParams, !currentJoints.isEmpty {
                    boneGroups.append(BoneGroup(
                        bones: currentJoints,
                        center: spring.center ?? -1,
                        colliderGroups: vrm0ColliderGroupIndices,
                        comment: spring.name,
                        dragForce: current.dragForce,
                        gravityDir: VRM.Vector3(x: current.gravityDir[0], y: current.gravityDir[1], z: current.gravityDir[2]),
                        gravityPower: current.gravityPower,
                        hitRadius: current.hitRadius,
                        stiffiness: current.stiffness
                    ))
                }
            }
        }
        
        self.init(boneGroups: boneGroups, colliderGroups: vrm0ColliderGroups)
    }
}

public extension VRM {
    static func migrateMaterials(gltf: BinaryGLTF, vrm1: VRM1) throws -> [MaterialProperty] {
        guard let materials = gltf.jsonData.materials else { return [] }
        
        var properties: [MaterialProperty] = []
        
        for material in materials {
            let name = material.name ?? ""
            
            // Check for VRMC_materials_mtoon extension
            if let mtoon = material.extensions?.materialsMToon {
                
                // Map MToon parameters to VRM 0.x MaterialProperty
                var floatProperties: [String: Double] = [:]
                let keywordMap: [String: Bool] = [:]
                var textureProperties: [String: Int] = [:]
                var vectorProperties: [String: [Double]] = [:] // VRM0.x expects [Double] (array of 4)
                
                // ShadeColor
                if let shadeColorFactor = mtoon.shadeColorFactor {
                    vectorProperties["_ShadeColor"] = shadeColorFactor + (shadeColorFactor.count == 3 ? [1.0] : [])
                }
                
                // Color (BaseColor)
                if let pbr = material.pbrMetallicRoughness {
                    let baseColor = pbr.baseColorFactor
                    vectorProperties["_Color"] = [Double(baseColor.r), Double(baseColor.g), Double(baseColor.b), Double(baseColor.a)]
                }
                
                // ShadingShift
                if let shadingShiftFactor = mtoon.shadingShiftFactor {
                    floatProperties["_ShadingShift"] = shadingShiftFactor
                }
                
                // ShadingToony
                if let shadingToonyFactor = mtoon.shadingToonyFactor {
                    floatProperties["_ShadingToony"] = shadingToonyFactor
                }
                
                // GiEqualization
                if let giEqualizationFactor = mtoon.giEqualizationFactor {
                    floatProperties["_GiEqualization"] = giEqualizationFactor
                }
                
                // RimColor
                if let parametricRimColorFactor = mtoon.parametricRimColorFactor {
                     vectorProperties["_RimColor"] = parametricRimColorFactor + (parametricRimColorFactor.count == 3 ? [1.0] : [])
                }
                if let parametricRimFresnelPowerFactor = mtoon.parametricRimFresnelPowerFactor {
                    floatProperties["_RimFresnelPower"] = parametricRimFresnelPowerFactor
                }
                if let parametricRimLiftFactor = mtoon.parametricRimLiftFactor {
                    floatProperties["_RimLift"] = parametricRimLiftFactor
                }
                
                // Outline
                if let outlineWidthMode = mtoon.outlineWidthMode {
                     let mode: Double
                     switch outlineWidthMode {
                     case .worldCoordinates: mode = 1
                     case .screenCoordinates: mode = 2
                     default: mode = 0
                     }
                     floatProperties["_OutlineWidthMode"] = mode
                }
                if let outlineWidthFactor = mtoon.outlineWidthFactor {
                    floatProperties["_OutlineWidth"] = outlineWidthFactor
                }
                if let outlineColorFactor = mtoon.outlineColorFactor {
                    vectorProperties["_OutlineColor"] = outlineColorFactor + (outlineColorFactor.count == 3 ? [1.0] : [])
                }
                if let outlineLightingMixFactor = mtoon.outlineLightingMixFactor {
                    floatProperties["_OutlineLightingMix"] = outlineLightingMixFactor
                }
                
                // Texture references
                if let index = mtoon.shadeMultiplyTexture?.index {
                    textureProperties["_ShadeTexture"] = index
                }
                if let index = mtoon.matcapTexture?.index {
                    textureProperties["_SphereAdd"] = index // MatCap
                }
                if let index = mtoon.rimMultiplyTexture?.index {
                    textureProperties["_RimTexture"] = index
                }
                if let index = mtoon.outlineWidthMultiplyTexture?.index {
                    textureProperties["_OutlineWidthTexture"] = index
                }
                
                // MainTex (BaseColorTexture)
                if let pbr = material.pbrMetallicRoughness, let baseTex = pbr.baseColorTexture {
                    textureProperties["_MainTex"] = baseTex.index
                }
                // BumpMap (NormalTexture)
                if let normalTex = material.normalTexture {
                    textureProperties["_BumpMap"] = normalTex.index
                }
                // EmissionMap (EmissiveTexture)
                if let emissiveTex = material.emissiveTexture {
                    textureProperties["_EmissionMap"] = emissiveTex.index
                }
                
                properties.append(MaterialProperty(
                    name: name,
                    shader: "VRM/MToon",
                    renderQueue: 2000,
                    floatProperties: CodableAny(floatProperties),
                    keywordMap: keywordMap,
                    tagMap: [:],
                    textureProperties: textureProperties,
                    vectorProperties: CodableAny(vectorProperties)
                ))
            } else {
                // Standard PBR or Unlit (KHR_materials_unlit)
                var floatProperties: [String: Double] = [:]
                var keywordMap: [String: Bool] = [:]
                var textureProperties: [String: Int] = [:]
                var vectorProperties: [String: [Double]] = [:]
                var tagMap: [String: String] = [:]
                
                // Check for KHR_materials_unlit extension
                let isUnlit = material.extensions?.materialsUnlit != nil
                
                // Determine shader based on material type
                let shader: String
                var renderQueue = 2000
                
                // Alpha mode handling
                switch material.alphaMode {
                case .OPAQUE:
                    renderQueue = 2000
                    tagMap["RenderType"] = "Opaque"
                case .MASK:
                    renderQueue = 2450
                    tagMap["RenderType"] = "TransparentCutout"
                    floatProperties["_Cutoff"] = Double(material.alphaCutoff)
                case .BLEND:
                    renderQueue = 3000
                    tagMap["RenderType"] = "Transparent"
                }
                
                if isUnlit {
                    shader = "VRM/UnlitTexture"
                } else {
                    shader = "Standard" // Unity Standard shader for PBR
                }
                
                // PBR properties
                if let pbr = material.pbrMetallicRoughness {
                    // BaseColor -> _Color
                    let baseColor = pbr.baseColorFactor
                    vectorProperties["_Color"] = [Double(baseColor.r), Double(baseColor.g), Double(baseColor.b), Double(baseColor.a)]
                    
                    // Metallic
                    floatProperties["_Metallic"] = Double(pbr.metallicFactor)
                    
                    // Roughness -> Glossiness (inverted)
                    // Unity Standard uses Smoothness (1 - roughness)
                    floatProperties["_Glossiness"] = Double(1.0 - pbr.roughnessFactor)
                    
                    // BaseColorTexture -> _MainTex
                    if let baseTex = pbr.baseColorTexture {
                        textureProperties["_MainTex"] = baseTex.index
                    }
                    
                    // MetallicRoughnessTexture -> _MetallicGlossMap
                    if let mrTex = pbr.metallicRoughnessTexture {
                        textureProperties["_MetallicGlossMap"] = mrTex.index
                    }
                }
                
                // Normal map
                if let normalTex = material.normalTexture {
                    textureProperties["_BumpMap"] = normalTex.index
                    floatProperties["_BumpScale"] = Double(normalTex.scale)
                    keywordMap["_NORMALMAP"] = true
                }
                
                // Occlusion map
                if let occTex = material.occlusionTexture {
                    textureProperties["_OcclusionMap"] = occTex.index
                    floatProperties["_OcclusionStrength"] = Double(occTex.strength)
                }
                
                // Emissive
                let emissive = material.emissiveFactor
                vectorProperties["_EmissionColor"] = [Double(emissive.r), Double(emissive.g), Double(emissive.b), 1.0]
                if emissive.r > 0 || emissive.g > 0 || emissive.b > 0 {
                    keywordMap["_EMISSION"] = true
                }
                
                if let emissiveTex = material.emissiveTexture {
                    textureProperties["_EmissionMap"] = emissiveTex.index
                    keywordMap["_EMISSION"] = true
                }
                
                // DoubleSided
                if material.doubleSided {
                    floatProperties["_Cull"] = 0 // Off
                }
                
                properties.append(MaterialProperty(
                    name: name,
                    shader: shader,
                    renderQueue: renderQueue,
                    floatProperties: CodableAny(floatProperties),
                    keywordMap: keywordMap,
                    tagMap: tagMap,
                    textureProperties: textureProperties,
                    vectorProperties: CodableAny(vectorProperties)
                ))
            }
        }
        
        return properties
    }
}
