# Sandbox V2 — MVP B | Rust + Bevy + GPU Compute

**Estado final (25/11/2026): B17 funcionalmente aprovada, com ressalvas de desempenho e escopo.** E2E Windows/Vulkan aprovado, revisão visual interativa aprovada pelo usuário e três benchmarks locais com 59,8–59,9 FPS médios. A homologação estrita de 60 FPS/16,7 ms na apresentação física não foi concluída. O contrato original permanece inalterado.

**Referência final:** `checkpoint/b17-final-mvp-20261125`. Fonte do runtime aprovado: `14e8806acfa4f4413278266789db7b2b7dd1519f`. Preservado o checkpoint visual anterior B15.5. B17 integra slabs fixos, culling conservador e terreno distante assíncrono, habilitados pelo launcher; não foram alterados os defaults do motor.

## Executar a versão final (Windows/Vulkan)

Baixe o artefato completo [b17-windows-runtime](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45688167846/artifacts/15059233222) ou utilize GitHub CLI:

```powershell
$root="C:\Dev\sandbox-b17-final"
New-Item -ItemType Directory -Force -Path "$root\app" | Out-Null
gh run download 45688167846 --repo publiomcko-labs/sandbox_v2_mvp_rustBevy --name b17-windows-runtime --dir "$root\app"
powershell -NoProfile -ExecutionPolicy Bypass -File "$root\app\b17-play.ps1"
```

Extraia/preserve `assets/shaders` e utilize o launcher incluído, que ativa as flags aprovadas e utiliza os journals locais de terreno e rochas. O binário isolado não equivale à configuração aprovada. O artefato Actions tem retenção limitada.

- [Relatório final B17: E2E, benchmark interativo e limitações](docs/B17_FINAL_MVP_20261125.md)
- [Backlog pós-MVP](docs/POST_MVP_ROADMAP.md)
- [Execução E2E integrada B17](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45688167846)

## Objetivo

Validar do zero um sandbox 3D de terreno volumétrico SDF editável, cavernas, streaming contínuo e renderização orientada à GPU, com rochas físicas e água básica. Este repositório não reutiliza código ou arquitetura de projetos anteriores.

## Stack proposta

- Rust stable fixado por `rust-toolchain.toml` e Bevy 0.20.x fixado por `Cargo.lock`.
- wgpu integrado ao renderizador Bevy para compute shaders WGSL, buffers persistentes e desenho indireto.
- Avian 3D para física, após validar uma combinação exata de versões compatíveis.
- Windows/Vulkan como plataforma inicial; fallback para hardware sem mesh shaders.

## Aceite obrigatório

| Métrica | Requisito |
| --- | --- |
| Frame completo | 60 FPS; orçamento de até **16,7 ms por frame** |
| Deslocamento | **18 m/s** contínuos, sem regiões desaparecendo ou piscando |
| Horizonte visual | **130 m de raio**, 360°, com LOD, terreno, rochas e água |
| Edição | **até 100 ms**, do comando ao frame que apresenta a alteração |
| Física | Colisões, gravidade e atrito de rochas; empuxo/arrasto e interação com água |
| Persistência | Restaurar terreno editado e estados alterados dos objetos |

Os critérios abaixo são o contrato original, não uma declaração de homologação integral. Consulte o relatório final B17 para os resultados e as limitações.

- [B1: SDF determinístico, WGSL e testes de paridade](docs/B1_IMPLEMENTATION.md)
- [B2: extração Surface Nets residente na GPU](docs/B2_IMPLEMENTATION.md)

## Documentação

- [Especificação técnica do MVP B](docs/MVP_B_RUST_BEVY_GPU_COMPUTE.md)
- [Contrato comum de requisitos e benchmarks](docs/CRITERIOS_COMUNS.md)
- [Implementação e validação B0](docs/B0_IMPLEMENTATION.md)

## Configuração integrada B17 (Windows/Vulkan)

| Flag de ambiente | Efeito | Estado |
|---|---|---|
| `SANDBOX_B15_5_FIXED_SLABS=1` | Slabs GPU fixos de 32 MiB; evita realocação coletiva de malhas | Aprovado visualmente |
| `SANDBOX_B15_6_CONSERVATIVE_CULLING=1` | AABB conservador para culling do terreno GPU | E2E e visual integrado B17 aprovados |
| `SANDBOX_B16_ASYNC_FAR_SHELL=1` | Reconstrói o B11 distante fora da thread principal | E2E e visual integrado B17 aprovados |
| `SANDBOX_B3_BENCH_UNCAPPED=1` | Remove a espera de 16 ms **apenas em testes headless** | Diagnóstico; não alterar a versão interativa |

Para executar o sandbox completo no runtime extraído, use `SANDBOX_STAGE=B11` e habilite explicitamente as opções desejadas. Preserve `assets/shaders` junto ao executável. Os documentos [B15.6](docs/B15_6_CONSERVATIVE_CULLING_E2E_RESULTS.md), [B15.7](docs/B15_7_HEADLESS_PACING_20261125.md) e [B16](docs/B16_ASYNC_FAR_SHELL_E2E_20261125.md) registram os resultados e as limitações.

## Sequência inicial (histórico)

1. Fixar toolchain/dependências e obter um executável de janela 3D reproduzível.
2. Implementar o campo SDF e pipeline GPU de classificação, extração de malha e desenho.
3. Implantar streaming com LOD e buffers de região persistentes, sem readback maciço por frame.
4. Integrar edição, colisão local, rochas com física, água e persistência.
5. Automatizar percurso frio/quente e edição em movimento; medir CPU, GPU, memória e frame apresentado.

**Regra de continuidade:** estado do mundo independente do renderizador, buffers e versões por região, troca atômica de geometria pronta e proibição de descarte visual prematuro. Trabalhos extensos e readbacks não podem bloquear a thread principal.

## Execução das etapas iniciais (histórico)

A B0 compilou e apresentou os dois cubos GPU no Windows/Vulkan. A B2 usa a mesma integração do MeshAllocator com GPU compute para gerar uma amostra estática de terreno SDF; o stream de 130m é B3. Para executar o artefato baixado do Actions, extraia-o preservando `assets/shaders/compute_mesh.wesl` e abra o terminal na raiz extraída antes de executar `./sandbox-game.exe`.

```powershell
git fetch origin
git switch feat/b0-rust-bevy-gpu-bootstrap-20261118
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-b0.ps1
```

A janela B0 mostra cubos gerados por compute shader em GPU, câmera com teclas WASD/Q/E (18 m/s), e métricas preliminares do Bevy. **Não** inclui terreno SDF, horizonte 130 m, streaming nem métricas completas de apresentação. O `Cargo.lock` já está versionado; o workflow compila usando `--locked`.


### B2 — execução local do artefato de CI

Extraia todo o pacote, incluindo `assets/shaders/sdf_density.wgsl` e
`assets/shaders/surface_nets.wgsl`, abra PowerShell na raiz extraída e execute:

```powershell
.\sandbox-game.exe
```

Variantes: `$env:SANDBOX_B2_LOD="0"` (grade de 0,5 m), `$env:SANDBOX_B2_SCENE="cave"`
(teste da caverna) e `$env:SANDBOX_STAGE="B0"` (prova anterior dos cubos).
No modo B2, o arquivo completo de shader deve acompanhar o executável.
