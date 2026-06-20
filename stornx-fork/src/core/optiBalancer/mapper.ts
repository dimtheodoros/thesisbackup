import { Config } from '../../config/config.js';

import type { DestinationRule, DistributedPercentTraffic } from './types.js';
import type { ClusterTopology } from '../../adapters/k8s/types.js';

function normalizeTo100(m: Record<string, number>): Record<string, number> {
  const entries = Object.entries(m);
  if (entries.length === 0) return {};
  const sum = entries.reduce((a, [, v]) => a + v, 0) || 1;
  const floats = entries.map(([k, v]) => [k, (v / sum) * 100] as const);
  const floors = floats.map(([k, f]) => [k, Math.floor(f)] as const);
  let used = floors.reduce((a, [, v]) => a + v, 0);
  const rema = floats.map(([k, f], i) => ({ k, r: f - floors[i][1] })).sort((a, b) => b.r - a.r);
  const out = Object.fromEntries(floors) as Record<string, number>;
  for (let i = 0; used < 100 && i < rema.length; i++, used++) out[rema[i].k] += 1;
  return out;
}

export const OptiBalancerMapper = {
  toDestinationRule: (
    trafficRules: DistributedPercentTraffic[],
    namespace: string,
    svc: string,
    clusterTopology: ClusterTopology[]
  ): DestinationRule => {
    const trafficRulesTopology = trafficRules
      .map((tr) => {
        const nodeFrom = clusterTopology.find((ct) => ct.node === tr.from);

        const nodeTo = clusterTopology.find((ct) => ct.node === tr.to);

        if (!nodeFrom || !nodeTo) {
          return;
        }

        return {
          from: `${nodeFrom.region}/${nodeFrom.zone}/${nodeFrom.node}`,
          to: `${nodeTo.region}/${nodeTo.zone}/${nodeTo.node}`,
          percentage: tr.percentage,
        };
      })
      .filter(Boolean) as DistributedPercentTraffic[];

    const groupedTraffic: Record<string, Record<string, number>> = {};

    trafficRulesTopology.forEach(({ from, to, percentage }) => {
      if (!groupedTraffic[from]) {
        groupedTraffic[from] = {};
      }
      groupedTraffic[from][to] = percentage;
    });

    const distributeRules = Object.entries(groupedTraffic).map(([from, toMap]) => ({
      from,
      to: normalizeTo100(toMap),
    }));

    // Istio: only one of distribute, failover, or failoverPriority may be set
    // on a single localityLbSetting. distribute is a closed weighted map
    // (localities absent from it get zero traffic permanently, even under
    // outlierDetection ejection); it can't express cross-cluster failover
    // because clusterTopology only ever contains this cluster's own nodes.
    // failover is the open, priority-based mode that actually falls back to
    // the remote region once outlierDetection ejects local endpoints.
    const localRegion = clusterTopology[0]?.region ?? '';
    const localityLbSetting = Config.FAILOVER_REGION
      ? {
          enabled: true,
          failover: [
            { from: localRegion, to: Config.FAILOVER_REGION },
            { from: Config.FAILOVER_REGION, to: localRegion },
          ],
        }
      : {
          enabled: true,
          distribute: distributeRules,
        };

    return {
      apiVersion: 'networking.istio.io/v1beta1',
      kind: 'DestinationRule',
      metadata: {
        name: svc,
        namespace: namespace,
      },
      spec: {
        host: `${svc}.${namespace}.svc.cluster.local`,
        trafficPolicy: {
          loadBalancer: {
            simple: 'LEAST_REQUEST',
            warmup: {
              duration: '2m',
              minimumPercent: 2.0,
            },
            localityLbSetting,
          },
          outlierDetection: {
            consecutive5xxErrors: 5,
            interval: '5s',
            baseEjectionTime: '30s',
            maxEjectionPercent: 50,
          },
          connectionPool: {
            tcp: { maxConnections: 500, connectTimeout: '2s' },
            http: {
              http1MaxPendingRequests: 500,
              http2MaxRequests: 1000,
              maxRequestsPerConnection: 0,
              h2UpgradePolicy: 'UPGRADE',
            },
          },
        },
      },
    };
  },
};
