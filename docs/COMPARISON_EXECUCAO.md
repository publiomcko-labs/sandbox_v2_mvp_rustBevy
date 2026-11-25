# Comparação V1 — execução e interpretação

Use o mesmo contrato presente nos dois repositórios, a mesma máquina Windows com sessão gráfica interativa e os scripts de cada engine.

Godot: abra PowerShell no repositório \`sandbox_v2_mvp_godotVoxel\`, obtenha o runtime aprovado A5, execute \`.\scripts\comparison-v1-windows.ps1 -Profile cold\`. O runner cria o SQLite em uma pasta \`world\` sob o diretório de resultado. Para revisita, execute \`.\scripts\comparison-v1-windows.ps1 -Profile warm -StateRoot "CAMINHO_DO_MESMO_WORLD"\`.

Bevy: abra PowerShell no repositório \`sandbox_v2_mvp_rustBevy\`, execute \`.\scripts\comparison-v1-windows.ps1 -Build -Profile cold\` para compilar o mesmo checkout de benchmark, com Vulkan e otimizações B17. Para revisita, execute \`.\scripts\comparison-v1-windows.ps1 -Profile warm -StateRoot "CAMINHO_DO_MESMO_WORLD"\`.

Cada sessão grava \`frames.csv\`, \`metadata.json\` e \`comparison-v1-result.json\`. No Bevy ficam também \`stdout.log\` e \`stderr.log\`. São intervalos entre inícios de frame, não latência de monitor. Os adaptadores de edição ainda precisam passar por um runtime smoke nesta branch; nunca omitir edições rejeitadas.

Depois de três rodadas de cada projeto por perfil e no mesmo hardware, executar o redutor comum em qualquer dos repositórios:

\`\`\`powershell
python .\scripts\comparison-v1-compare.py --godot "A1\comparison-v1-result.json" "A2\comparison-v1-result.json" "A3\comparison-v1-result.json" --bevy "B1\comparison-v1-result.json" "B2\comparison-v1-result.json" "B3\comparison-v1-result.json" --out "comparison-pair.json"
\`\`\`

Para uma única rodada exploratória, adicionar \`--exploratory\`. O comparador recusa dados headless e metadados de CPU, GPU/driver, máquina, perfil, cenário, resolução e hashes contratuais divergentes.

**Limitação decisiva:** geometria/seed/carga de física não são equivalentes; runtimes têm configurações de build distintas (Godot editor + DLL nativa A5; Rust Release B17). Portanto, valores médios e percentis orientam investigação, mas não estabelecem um vencedor técnico isolado nem substituem uma comparação com builds Release e conteúdo equivalente. Nenhum relatório declara o cumprimento estrito dos 60 FPS, 130m visuais ou EDIT-100 com base em frame starts/proxies.
