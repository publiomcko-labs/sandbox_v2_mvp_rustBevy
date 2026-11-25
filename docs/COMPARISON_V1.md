# Comparação padronizada V1 — Godot/Voxel Tools vs Rust/Bevy

O objetivo é comparar os **mesmos padrões de movimento e edições**, sem modificar a implementação normal do jogo. Usar branches isoladas e não promover automaticamente o candidato de melhor FPS.

## Contrato compartilhado

Arquivo \`benchmarks/comparison-v1.json\` (conteúdo idêntico nos dois repositórios). Cenário: janela 1080p, 12 s parado para warm-up, leste (+X) de t=12 a 30 s e norte (-Z) de t=30 a 46 s a **18 m/s**; seis brushes de raio **1,5 m** alternando remoção/adição em t=25,28,31,34,37,40 s. O benchmark termina em t=46 s. Terreno e seed são próprios de cada protótipo e **não têm complexidade igual**.

A janela de medição é t=12..46 s. O arquivo CSV contém \`t_s,interval_ms\` (intervalos monotônicos entre inícios de frames); o redutor idêntico produz JSON com p50/p95/p99/p99.9, máximo, média, 1%/0,1% low, contagens de frames >16,7/20/33 ms e metadados do ambiente.

**Não confundir:** intervalos entre inícios de frames, execução GPU-ready, frames apresentados no monitor e pixels corretos da edição são métricas diferentes. Nenhum teste headless qualifica FPS gráfico, VIEW-130 real, STREAM-18 sem falhas de pixels ou EDIT-100 ponta a ponta.

## Execução

Utilizar a MESMA máquina Windows, mesma GPU/driver, sessão de desktop interativa, resolução 1920×1080, energia em alto desempenho, software em segundo plano controlado, sem gravar a tela na campanha de performance. Rodar \`scripts/comparison-v1-windows.ps1\` no repositório de cada engine (help e pré-requisitos no próprio script), salvar relatórios separados por run.

Recomendado: três replicações por candidato alternadas A–B–B–A (com rodada adicional para completar 3/3), mesmo modo de alimentação e aquecimento semelhante. Dois perfis de estado: "cold" com novos journals e "warm" com journals previamente gerados; **registrar qual foi usado**. A execução não deve apagar saves de produção. Não misturar headless com desktop no ranking.

Requisitos de validade: métricas não vazias, instrumentação in-memory, cenário completo, flags/commit fixados, falhas de edição registradas, ausência de troca de cena/configuração escondida. Métricas de GPU, VRAM e apresentação física exigem ferramenta externa comprovadamente funcional; marcar \`NOT_MEASURED\` se ausentes. Não usar a captura de vídeo para calcular os mesmos percentis da campanha sem captura.

## Comparabilidade limitada

O Godot usa Voxel Tools SDF/Transvoxel e GL Compatibility; o Bevy usa SDF/Surface Nets GPU e Vulkan. Mesmo com rota e tamanho de brush idênticos, a geometria, quantidade de objetos e esforço de física não são iguais. Este teste é uma **comparação de runtime de MVP representativo**, não um benchmark isolado de eficiência do mesher nem prova da superioridade de linguagem.

Para decisão de produção, adicionar posteriormente uma carga sintética com malhas/células/objetos equivalentes e um observador de pixels em apresentação real, sem reabrir automaticamente campanhas exaustivas.

## Gates

O redutor marca PERF-60, STREAM-18, VIEW-130 e EDIT-100 como **não qualificados estritamente**, mesmo com métricas positivas, por ausência de medição integral de apresentação e cobertura. Operações rejeitadas, testes incompletos e erros de runtime não podem ser omitidos.
