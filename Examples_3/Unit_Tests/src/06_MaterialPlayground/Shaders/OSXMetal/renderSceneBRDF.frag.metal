/*
* Copyright (c) 2018 Confetti Interactive Inc.
*
* This file is part of The-Forge
* (see https://github.com/ConfettiFX/The-Forge).
*
* Licensed to the Apache Software Foundation (ASF) under one
* or more contributor license agreements.  See the NOTICE file
* distributed with this work for additional information
* regarding copyright ownership.  The ASF licenses this file
* to you under the Apache License, Version 2.0 (the
* "License") you may not use this file except in compliance
* with the License.  You may obtain a copy of the License at
*
*   http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing,
* software distributed under the License is distributed on an
* "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
* KIND, either express or implied.  See the License for the
* specific language governing permissions and limitations
* under the License.
*/
#include <metal_stdlib>
using namespace metal;

struct Light
{
	float4 pos;
	float4 col;
	float radius;
	float intensity;
	float _pad0;
	float _pad1;
};

static constant float PI = 3.14159265359;

struct CameraData
{
	float4x4 projView;
	float3 camPos;
};

struct ObjectData
{
	float4x4 worldMat;
	float roughness;
	float metalness;
	int objectId;
};

struct LightData
{
	Light lights[16];
	int currAmountOflights;
};

struct VSOutput
{
	float4 position[[position]];
	float3 pos;
	float3 normal;
	float2 uv;
};

float3 FresnelSchlickRoughness(float cosTheta, float3 F0, float roughness)
{
	return F0 + (max(float3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}

float3 fresnelSchlick(float cosTheta, float3 F0)
{
	return F0 + (1.0f - F0) * pow(1.0 - cosTheta, 5.0);
}

float distributionGGX(float3 N, float3 H, float roughness)
{
	float a = roughness * roughness;
	float a2 = a * a;
	float NdotH = max(dot(N, H), 0.0);
	float NdotH2 = NdotH * NdotH;
	float nom = a2;
	float denom = (NdotH2 * (a2 - 1.0) + 1.0);
	denom = PI * denom * denom;

	return nom / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
	float r = (roughness + 1.0f);
	float k = (r * r) / 8.0f;

	float nom = NdotV;
	float denom = NdotV * (1.0 - k) + k;

	return nom / denom;
}

float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
	float NdotV = max(dot(N, V), 0.0);
	float NdotL = max(dot(N, L), 0.0);
	float ggx2 = GeometrySchlickGGX(NdotV, roughness);
	float ggx1 = GeometrySchlickGGX(NdotL, roughness);

	return ggx1 * ggx2;
}

float3 getNormalFromMap(texture2d<float> normalMap, sampler defaultSampler, float2 uv, float3 pos, float3 normal)
{

	float3 tangentNormal = normalMap.sample(defaultSampler, uv).rgb * 2.0 - 1.0;

	float3 Q1 = dfdx(pos);
	float3 Q2 = dfdy(pos);
	float2 st1 = dfdx(uv);
	float2 st2 = dfdy(uv);

	float3 N = normalize(normal);
	float3 T = normalize(Q1 * st2.g - Q2 * st1.g);
	float3 B = -normalize(cross(N, T));
	float3x3 TBN = float3x3(T, B, N);
	float3 res = TBN * tangentNormal;
	return res;
}

fragment float4 stageMain(VSOutput In[[stage_in]],
						  constant CameraData &cbCamera[[buffer(1)]],
						  constant ObjectData &cbObject[[buffer(2)]],
						  constant LightData &cbLights[[buffer(3)]],
						  texture2d<float, access::sample> brdfIntegrationMap[[texture(0)]],
						  texturecube<float, access::sample> irradianceMap[[texture(1)]],
						  texture2d<float> albedoMap[[texture(2)]],
						  texture2d<float, access::sample> normalMap[[texture(3)]],
						  texture2d<float, access::sample> metallicMap[[texture(4)]],
						  texture2d<float, access::sample> roughnessMap[[texture(5)]],
						  texture2d<float, access::sample> aoMap[[texture(6)]],
						  texturecube<float, access::sample> specularMap[[texture(7)]],
						  sampler envSampler[[sampler(0)]],
						  sampler defaultSampler[[sampler(1)]])
{
	// default albedo before sampling
	float3 albedo = float3(0.5f, 0.0f, 0.0f);
	float ao = 1.0f;
	float _roughness = cbObject.roughness;
	float _metalness = cbObject.metalness;
	float3 N = In.normal;

	if (cbObject.objectId != -1)
	{
		N = getNormalFromMap(normalMap, defaultSampler, In.uv, In.pos, N);
		float3 val = albedoMap.sample(defaultSampler, In.uv, 0.0).rgb;
		albedo = float3(pow(val.x, 2.2f), pow(val.y, 2.2f), pow(val.z, 2.2f));
		_metalness = metallicMap.sample(defaultSampler, In.uv).r;
		_roughness = roughnessMap.sample(defaultSampler, In.uv).r;
		ao = aoMap.sample(defaultSampler, In.uv).r;
		if (cbObject.objectId == 2)
		{
			albedo = float3(0.1f, 0.1f, 0.1f);
			_roughness = 1.0f;
		}
		else if (cbObject.objectId == 3)
		{
			albedo = float3(0.8f, 0.1f, 0.1f);
		}
	}

	N = normalize(N);
	float3 V = normalize(cbCamera.camPos - In.pos);
	float3 R = normalize(reflect(-V, N));

	// 0.04 is the index of refraction for metal
	float3 F0 = float3(0.04f, 0.04f, 0.04f);
	F0 = mix(F0, albedo.rgb, _metalness);

	// Lo = outgoing radiance
	float3 Lo = float3(0.0f, 0.0f, 0.0f);
	for (int i = 0; i < cbLights.currAmountOflights; ++i)
	{
		float3 L = normalize(cbLights.lights[i].pos.rgb - In.pos);

		float3 H = normalize(V + L);

		float distance = length(cbLights.lights[i].pos.xyz - In.pos);

		float distanceByRadius = 1.0f - pow((distance / cbLights.lights[i].radius), 4);
		float clamped = pow(saturate(distanceByRadius), 2.0f);
		float attenuation = clamped / (distance * distance + 1.0f);

		float3 radiance = cbLights.lights[i].col.rgb * attenuation * cbLights.lights[i].intensity;

		float NDF = distributionGGX(N, H, _roughness);
		float G = GeometrySmith(N, V, L, _roughness);
		float3 F = fresnelSchlick(max(dot(N, H), 0.0), F0);

		float3 nominator = NDF * G * F;
		float denominator = 4.0f * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.001;
		float3 specular = nominator / denominator;

		float3 kS = F;

		float3 kD = float3(1.0, 1.0f, 1.0f) - kS;

		kD *= 1.0f - _metalness;

		float NdotL = max(dot(N, L), 0.0);

		Lo += (kD * albedo.rgb / PI + specular) * radiance * NdotL;
	}

	// Ambient-term.
	float3 F = FresnelSchlickRoughness(max(dot(N, V), 0.0), F0, _roughness);
	float3 kS = F;
	float3 kD = float3(1.0) - kS;
	kD *= 1.0 - _metalness;

	float3 irradiance = irradianceMap.sample(envSampler, N).rgb;
	float3 diffuse = kD * irradiance * albedo.rgb;

	
	uint mipLevel = (uint)(_roughness * 4.0f);
	float3 specularColor = specularMap.sample(envSampler, R, level(mipLevel)).rgb;
	
	float2 brdf = brdfIntegrationMap.sample(defaultSampler, float2(max(dot(N, V), 0.0), _roughness)).rg;
	float3 specular = specularColor * (F * brdf.x + brdf.y);

	float3 ambient = (diffuse + specular) * float3(ao);
	float3 color = ambient + Lo;
	color = color / (color + float3(1.0f));

	float gammaCorr = 1.0f / 2.2f;

	color.r = pow(color.r, gammaCorr);
	color.g = pow(color.g, gammaCorr);
	color.b = pow(color.b, gammaCorr);

	return float4(color.r, color.g, color.b, 1.0f);
}
