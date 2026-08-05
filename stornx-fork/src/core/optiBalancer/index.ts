// optiBalancer/index.ts
import { TrafficEngine } from './engine.js';
import { OptiBalancerMapper } from './mapper.js';
import { Config } from '../../config/config.js';
import { logger } from '../../config/logger.js';

import type { DestinationRule, DistributedPercentTraffic, OptiScalerType } from './types.js';
import type { KubernetesAdapterImpl } from '../../adapters/k8s/index.js';
import type { PrometheusAdapterImpl } from '../../adapters/prometheus/index.js';
import type { MetricsType } from '../../enums.js';

export class OptiBalancer {
  private readonly k8s: KubernetesAdapterImpl;
  private readonly prom: PrometheusAdapterImpl;
  private readonly metricType: MetricsType;
  private readonly loggerOperation = logger.child({ operation: 'OptiBalancer' });
  private readonly engine: TrafficEngine;

  constructor(k8s: KubernetesAdapterImpl, prometheus: PrometheusAdapterImpl, metricType: MetricsType) {
    this.k8s = k8s;
    this.prom = prometheus;
    this.metricType = metricType;
    this.engine = new TrafficEngine(metricType);
  }

  async Execute(data: OptiScalerType) {
    const upstream = await this.prom.getUpstreamPodGraph(data.deployment, data.namespace);
    if (!upstream || upstream.length === 0) {
      return;
    }

    this.loggerOperation.info(`Initialize traffic distribution rules`, {
      deployment: data.deployment,
      namespace: data.namespace,
    });

    // Fetch P95 response time per node for this deployment
    const responseTimeData = await this.prom.getResponseTimeByNodeDeployment(data.deployment, data.namespace);
    const nodeResponseTimes = responseTimeData?.map((rt) => ({
      node: rt.node,
      responseTimeMs: rt.responseTime,
    }));

    // Average CPU usage across all local replicas (0-100 scale) — used to
    // compute how much traffic to pre-emptively shift to the remote cluster.
    const avgCpuPct =
      data.replicaPods.length > 0
        ? (data.replicaPods.reduce((sum, p) => sum + p.percentUsage.cpu, 0) / data.replicaPods.length) * 100
        : 0;
    const remoteWeight = this.engine.computeRemoteWeight(avgCpuPct);

    // --- Compute target distribution (delegated to TrafficEngine) ---
    // Now includes response time as a primary factor for weight calculation
    const targetList: DistributedPercentTraffic[] = this.engine.calculateTraffic(
      data.replicaPods,
      upstream,
      data.nodesLatency,
      nodeResponseTimes
    );

    const serviceName = upstream[0].destinations[0].destination_service_name;

    // ---- READ current DR from cluster
    const group = 'networking.istio.io';
    const version = 'v1beta1';
    const plural = 'destinationrules';

    const current = await this.k8s.readCustomResource(group, version, data.namespace, plural, serviceName);

    // if DR doesn't exist yet, apply target directly
    if (!current) {
      const dr = OptiBalancerMapper.toDestinationRule(targetList, data.namespace, serviceName, data.clusterTopology, remoteWeight);
      await this.applyTrafficRules(dr);
      return;
    }

    let currentDistribute: Array<{ from: string; to: Record<string, number> }> | undefined;

    const dist = current?.spec?.trafficPolicy?.loadBalancer?.localityLbSetting?.distribute;
    if (Array.isArray(dist)) {
      // trust the live DR as current
      currentDistribute = dist as Array<{ from: string; to: Record<string, number> }>;
    }

    // Target as per-from maps
    const targetDistribute = this.engine.percentListToDistribute(targetList);

    // If we have no live DR yet, apply target directly
    // Otherwise use adaptive stepping (larger steps when urgency is high)
    const nextDistribute = currentDistribute
      ? this.engine.stepTowardTarget(
          currentDistribute,
          targetDistribute,
          Config.balancer.minStepSize,
          Config.balancer.maxStepSize,
          Config.balancer.urgencyThreshold,
          Config.balancer.epsilon
        )
      : targetDistribute;

    // Optional: only apply if change is meaningful (sum of absolute diffs ≥ threshold)
    const delta = currentDistribute ? this.engine.l1Distance(currentDistribute, nextDistribute) : 100;

    if (delta < Config.balancer.minDeltaThreshold) {
      this.loggerOperation.info(`Skip apply (delta=${delta.toFixed(2)} < ${Config.balancer.minDeltaThreshold})`);
      return;
    }

    // Convert back to your flat list for the mapper
    const nextList = this.engine.distributeToPercentList(nextDistribute);

    const createDestinationRule = OptiBalancerMapper.toDestinationRule(
      nextList,
      data.namespace,
      serviceName,
      data.clusterTopology,
      remoteWeight
    );

    // console.log(JSON.stringify(createDestinationRule, null, 2));

    await this.applyTrafficRules(createDestinationRule);
  }

  private async applyTrafficRules(createDestinationRule: DestinationRule) {
    await this.k8s.applyCustomResource(createDestinationRule);
  }
}
