# Backlog pós-MVP — Rust + Bevy + GPU Compute

Referência: B17 aprovada funcionalmente em 25/11/2026. O backlog é proposta de trabalho futuro, não lista de entregas já executadas nem autorização para campanhas adicionais no MVP.

| Prioridade | Item | Objetivo e critério futuro |
|---|---|---|
| P0 | Picos residuais de frametime | Investigar apenas hipóteses apoiadas por evidência; reduzir cauda (1%/0.1% low) sem reintroduzir lacunas, realocações ou latência de edição. Meta de contrato: frame completo ≤16.7 ms; metas complementares 1% low ≥50 e 0.1% low ≥30 FPS. |
| P0 | Comparação com Godot/Voxel Tools | Comparar mesma máquina, cenário, seed/complexidade, resolução, rota, velocidade, critérios e escopo; distinguir métricas equivalentes, proxies e lacunas de evidência. Selecionar arquitetura definitiva com base em resultados. |
| P1 | Recursos/memória e pressão de slabs | Medir CPU/GPU, RAM/VRAM, picos, tamanho das filas e ocupação/fragmentação dos slabs fixos; definir orçamento de recursos e teste de longa duração. Não reintroduzir realocação coletiva de geometria viva. |
| P1 | Escalabilidade de edições e rochas | Validar índices espaciais, particionamento do journal, compactação, carga sob demanda, eviction e persistência de milhões de edições/estados sem varredura global ou memória ilimitada. Planejar migração versionada, testes de recuperação e save/reopen. |
| P1 | Água e costa | Melhorar máscara da costa após alterações de SDF, cursos de água locais e interação/nado/arrasto do personagem; preservar empuxo, continuidade e publicação coordenada com terreno. Não requer simulação hidrodinâmica completa. |
| P1 | Colisores e edição ponta a ponta | Medir input até primeiro pixel apresentado e latência de colisores; melhorar correspondência do SDF de 1 m com malha GPU quando a diferença causar defeitos. Testar adição/subtração, bordas, movimento e contato. |
| P2 | Qualificação de apresentação física | Somente quando necessária para decisão de arquitetura ou aceite estrito: captura confiável de frame apresentado, p50/p95/p99/p99.9, máximo e >20/33 ms; separar eventos de SO e aplicação. Preferir caminho leve validado em teste curto, não reabrir investigação ETW sem motivação. |
| P2 | Robustez de streaming e visibilidade | Ampliar cobertura das rotas/seeds contratuais, 360°, caminhos frios/quentes, transições LOD, água/rochas e edição; revalidar limites AABB conservadores se shaders mudarem. |
| P2 | Evolução do worker distante | Se concorrência ou portabilidade exigirem, trocar a thread nativa por pool limitado, mantendo apenas resultados da revisão/centro atual, backpressure e retenção da malha válida. |

## Regras de continuidade

- Preservar checkpoint B17 e configuração aprovada; cada intervenção parte de baseline imutável em branch isolada.
- Medir ganhos e regressões na mesma carga; automatizar pelo CI e reutilizar runtime e evidências sempre que possível.
- Só solicitar intervenção humana para gates visuais efetivamente necessários; não repetir campanhas exaustivas por rotina.
- Não alterar o contrato original para mascarar gaps de medição ou desempenho. Aprovação funcional não implica aprovação estrita.
- Priorizar decisão de arquitetura antes de ampliar escopo de produto. Sem implementação pós-MVP automática nesta etapa.
