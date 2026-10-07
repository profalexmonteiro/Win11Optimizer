# Otimização Windows 11 para VMware

Script PowerShell que reduz o consumo de memória do Windows 11 e melhora o desempenho de máquinas virtuais do VMware Workstation e do VMware Player, com **perfis de aplicação**, **registro de cada alteração** e **reversão automática**.

![Plataforma](https://img.shields.io/badge/plataforma-Windows%2011-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Versão](https://img.shields.io/badge/vers%C3%A3o-3.0-informational)

---

## Sumário

- [Visão geral](#visão-geral)
- [Requisitos](#requisitos)
- [Instalação e uso](#instalação-e-uso)
- [Perfis](#perfis)
- [O que o script altera](#o-que-o-script-altera)
- [Reversão](#reversão)
- [Arquivos gerados](#arquivos-gerados)
- [Resultados esperados](#resultados-esperados)
- [Limitações conhecidas](#limitações-conhecidas)
- [Perguntas frequentes](#perguntas-frequentes)
- [Aviso legal](#aviso-legal)

---

## Visão geral

Muitos scripts de "otimização" para Windows aplicam ajustes sem efeito real, desativam recursos importantes sem avisar e não oferecem forma de voltar atrás. Este projeto segue princípios diferentes:

- **Só aplica ajustes com efeito mensurável.** Ajustes ignorados pelo Windows 11 foram removidos. Os que só valem em alguns cenários são opcionais e trazem a explicação do custo.
- **Pergunta antes de mudar o que pode fazer falta.** Leitor de certificado digital (e-CPF), biometria, impressão, hotspot, Xbox e OneDrive nunca são desativados sem confirmação.
- **Toda alteração é reversível.** O valor original de cada chave de registro, serviço, arquivo de configuração, plano de energia e opção de boot é gravado antes da mudança.
- **Foco em virtualização.** Os maiores ganhos para uma VM vêm do hypervisor, da configuração de memória do VMware e da verificação do antivírus sobre os discos virtuais, e não de desativar serviços do Windows.

## Requisitos

| Item | Requisito |
|---|---|
| Sistema operacional | Windows 11 (Home, Pro, Enterprise ou Education) |
| PowerShell | Windows PowerShell 5.1, que já vem no Windows. O PowerShell 7 **não** é suportado. |
| Permissões | Conta de administrador |
| VMware (opcional) | VMware Workstation ou VMware Player, para as etapas de VM |
| Espaço em disco | Tamanho do pagefile escolhido + 4 GB livres no disco do sistema |

## Instalação e uso

1. Baixe os arquivos `Otimizar-Win11-v3.ps1` e `Executar.bat` e coloque os dois **na mesma pasta**.
2. Feche o VMware e desligue ou suspenda as VMs.
3. Dê dois cliques em `Executar.bat` e aceite o pedido de permissão de administrador.
4. No menu, escolha a opção **5 (Status)** para ver o estado atual do sistema.
5. Aplique um perfil (recomenda-se começar pelo **Seguro**).
6. Reinicie o computador quando o script pedir.

O `Executar.bat` usa `-ExecutionPolicy Bypass` apenas nessa execução. A política de execução do sistema não é alterada.

```text
======================================================
   Otimizacao Windows 11 v3.0 - RAM e VMware
======================================================
  1) Seguro     - telemetria, segundo plano, energia, pagefile, VMware global
  2) Agressivo  - Seguro + apps, servicos opcionais, VMs, Defender, Hyper-V/VBS
  3) So VMware  - apenas ajustes de desempenho das VMs
  4) Reverter   - desfaz TODAS as alteracoes registradas
  5) Status     - diagnostico do sistema
  6) Sair
```

## Perfis

| Perfil | Indicado para | Risco |
|---|---|---|
| **Seguro** | Qualquer computador. Não remove apps nem desativa recursos de uso comum. | Baixo |
| **Agressivo** | Máquinas dedicadas a virtualização. Todas as etapas sensíveis são perguntadas uma a uma. | Médio |
| **Só VMware** | Quem quer apenas o desempenho das VMs, sem mexer no restante do Windows. | Médio |

### Etapas por perfil

| Etapa | Seguro | Agressivo | Só VMware |
|---|:---:|:---:|:---:|
| Correção de ajustes de versões anteriores | ✔ | ✔ | ✔ |
| Telemetria e serviços sem uso | ✔ | ✔ | |
| Edge, Widgets, Recall, Bing e apps em segundo plano | ✔ | ✔ | |
| Pré-carregamento de apps e compressão de memória | ✔ | ✔ | |
| Efeitos visuais | ✔ | ✔ | |
| Tempo de encerramento de programas travados | ✔ | ✔ | |
| Plano de energia Desempenho Máximo | ✔ | ✔ | ✔ |
| Hibernação | ✔ | ✔ | |
| Pagefile de tamanho fixo | ✔ | ✔ | ✔ |
| Configuração global do VMware | ✔ | ✔ | ✔ |
| Serviços sensíveis (perguntados um a um) | | ✔ | |
| Impressão, Xbox, SysMain e indexação | | ✔ | |
| Remoção de apps pré-instalados | | ✔ | |
| OneDrive | | ✔ | |
| Ajustes em cada VM (`.vmx`) | | ✔ | ✔ |
| Exclusão no Windows Defender | | ✔ | ✔ |
| Desativação de Hyper-V/VBS | | ✔ | ✔ |
| Verificação de virtualização na BIOS | | ✔ | ✔ |
| Lista de programas de inicialização (somente leitura) | ✔ | ✔ | |

## O que o script altera

### Memória e processos em segundo plano

- Desativa o Startup Boost e o modo em segundo plano do Microsoft Edge.
- Desativa Widgets, Recall, Click to Do, sugestões do Bing no menu Iniciar e Game DVR.
- Impede que apps da Microsoft Store rodem em segundo plano.
- Desativa o pré-carregamento de apps da Store (`Disable-MMAgent -ApplicationPrelaunch`).
- Mantém a **compressão de memória ligada** e oferece religá-la se estiver desligada, porque ela reduz o uso de RAM.
- Remove apps pré-instalados que iniciam sozinhos (Teams pessoal, Vincular ao Celular, Copilot, Clipchamp, Notícias, Clima e outros), após mostrar a lista e pedir confirmação.

### Serviços

| Grupo | Serviços | Comportamento |
|---|---|---|
| Sem uso na maioria dos PCs | DiagTrack, dmwappushservice, WerSvc, MapsBroker, RetailDemo, wisvc, Fax, PhoneSvc, WpcMonSvc, CSCService | Desativados automaticamente |
| Podem fazer falta | WbioSrvc, SensorService, SCardSvr, lfsvc, SharedAccess | Perguntados um a um, com descrição do impacto |
| Uso específico | Spooler, serviços Xbox | Perguntados |
| Não recomendados | SysMain, WSearch | Perguntados, com recomendação de **manter** |

### Energia e memória virtual

- Ativa o plano **Desempenho Máximo** (Ultimate Performance) sem criar cópias duplicadas a cada execução. Em notebooks, pede confirmação antes.
- Desativa a hibernação, o que libera o `hiberfil.sys`, arquivo do tamanho da RAM.
- Define o **pagefile com tamanho fixo** (padrão de 16 GB, configurável), com tamanho inicial igual ao máximo, depois de verificar o espaço em disco.

### VMware

**Configuração global** (`%ProgramData%\VMware\VMware Workstation\config.ini`):

| Parâmetro | Valor | Efeito |
|---|---|---|
| `mainMem.useNamedFile` | `FALSE` | Elimina o arquivo `.vmem` e reduz o I/O em disco |
| `MemTrimRate` | `0` | Impede a recuperação de memória da VM em execução |
| `sched.mem.pshare.enable` | `FALSE` | Desativa a varredura de páginas compartilhadas |
| `prefvmx.minVmMemPct` | `100` | Opcional: reserva toda a RAM da VM na memória física |

**Prioridade** (`%APPDATA%\VMware\preferences.ini`): Alta quando a VM está em foco e Normal fora dela, pelo mecanismo nativo do próprio VMware.

**Ajustes em cada VM** (`.vmx`): aplica os mesmos parâmetros de memória, desativa a impressora virtual e, opcionalmente, a placa de som, além de reduzir a retenção de logs. Também emite alertas quando:

- a VM recebeu mais de 60% da RAM do host;
- a VM tem mais vCPUs do que núcleos físicos.

VMs abertas ou travadas (com arquivos `.lck`) são ignoradas.

### Segurança e hypervisor

- **Exclusão no Windows Defender** da pasta das VMs e do processo `vmware-vmx.exe`. Elimina a verificação em tempo real dos discos virtuais, um dos maiores gargalos de I/O.
- **Desativação de Hyper-V e VBS.** Com eles ativos, o VMware roda sobre a plataforma de hypervisor da Microsoft e perde desempenho. Desativá-los costuma ser o maior ganho individual para a VM.

> ⚠️ **Essas duas etapas reduzem a segurança do sistema.** Desativar o VBS desliga a Integridade de Memória, o Credential Guard, o WSL2, o Windows Sandbox e o Docker baseado em WSL2. Ambas são opcionais e explicadas antes da confirmação.

## Reversão

A opção **4 (Reverter)** desfaz todas as alterações registradas, na ordem inversa da aplicação.

| Tipo | Como é revertido |
|---|---|
| Chaves de registro | Valor e tipo originais restaurados, ou chave removida se não existia antes |
| Serviços | Tipo de inicialização original restaurado, incluindo "automático com atraso" |
| Arquivos `.ini` e `.vmx` | Restaurados a partir do backup feito antes da primeira alteração |
| Plano de energia | Plano original reativado e plano criado excluído |
| Hibernação | Religada, se estava ativa |
| Opção de boot do hypervisor | Valor original do `hypervisorlaunchtype` restaurado |
| Exclusões do Defender | Removidas |
| Gerenciador de memória | Pré-carregamento e compressão voltam ao estado original |

**Apps removidos não são reinstalados automaticamente.** O script lista quais foram removidos para que possam ser reinstalados pela Microsoft Store.

Além da reversão automática, um ponto de restauração do sistema é criado antes de cada perfil.

## Arquivos gerados

Todos ficam em `C:\ProgramData\OtimizacaoWin11\`:

| Arquivo | Conteúdo |
|---|---|
| `estado.json` | Registro dos valores originais, usado pela reversão |
| `log_AAAAMMDD_HHMMSS.txt` | Transcrição completa de cada execução |
| `backup\` | Cópias dos arquivos `.ini` e `.vmx` antes da alteração |
| `estado_revertido_*.json` | Registro arquivado após uma reversão |

## Resultados esperados

Os ganhos dependem do hardware e do que está instalado. Como referência:

| Área | Impacto típico |
|---|---|
| RAM em uso após o boot | Redução de 300 MB a 1 GB |
| Desempenho de CPU e I/O da VM com Hyper-V/VBS desativado | Maior ganho individual do script |
| I/O de disco da VM com exclusão no Defender | Ganho significativo em leitura e escrita |
| Engasgos da VM | Redução, com memória reservada e sem trimming |

### Como medir

1. Antes de aplicar, reinicie, aguarde cerca de 5 minutos e anote a memória **"Em uso"** no Gerenciador de Tarefas (Desempenho > Memória).
2. Rode um teste reproduzível dentro da VM, como uma compilação, um benchmark ou o tempo de boot.
3. Aplique o perfil, reinicie e repita as medições nas mesmas condições.

Compare a memória **em uso**, não a memória **livre**. O Windows usa a RAM ociosa como cache e a libera imediatamente quando um programa precisa dela.

## Limitações conhecidas

- **Não é possível limitar a memória do Windows a um valor fixo.** O sistema não oferece esse recurso. A abordagem correta é reservar a memória da VM (`prefvmx.minVmMemPct = 100`) para que o Windows use apenas o restante.
- **Políticas de telemetria:** nas edições Home e Pro, o Windows aplica no mínimo o nível "Obrigatório", mesmo com o valor configurado como 0.
- **Credential Guard bloqueado por UEFI** ou por política corporativa pode impedir a desativação do VBS pelo registro. Confirme o resultado pela opção 5 após reiniciar.
- **Computadores gerenciados por empresa** (Intune, GPO de domínio) podem sobrescrever as alterações ou bloquear exclusões do Defender.
- **Ajustes em `HKCU`** valem apenas para o usuário que executa o script.
- **Computadores com Modern Standby** podem não oferecer os planos Alto Desempenho e Desempenho Máximo.
- O script foi validado quanto à sintaxe e à lógica dos componentes independentes de plataforma. **Teste primeiro em um ambiente não crítico.**

## Perguntas frequentes

**Por que o SysMain não é desativado por padrão?**
Ele ocupa memória "em espera", que funciona como cache e é liberada na hora em que outro programa precisa dela. Desativá-lo faz parecer que há mais RAM livre, mas não aumenta a memória disponível para a VM e pode deixar a abertura de programas mais lenta.

**Por que a v3 removeu a prioridade Alta fixa do `vmware-vmx.exe`?**
Com prioridade Alta permanente, uma VM em carga total pode deixar o host sem resposta, inclusive o teclado e o mouse usados na própria VM. A prioridade nativa do VMware aplica o nível Alto apenas quando a VM está em foco.

**Por que o `Win32PrioritySeparation` não foi mantido?**
O valor 38 (`0x26`) usado em versões anteriores equivale ao comportamento padrão do Windows 11 cliente e não produz diferença mensurável.

**Posso rodar o script mais de uma vez?**
Sim. O script é idempotente: o valor original de cada item é registrado apenas na primeira vez, e o plano de energia não é duplicado.

**Funciona com VirtualBox ou Hyper-V?**
As etapas gerais do Windows funcionam. As etapas específicas de VMware são ignoradas se o VMware não estiver instalado. Quem usa Hyper-V **não** deve desativar o VBS e o hypervisor.

## Aviso legal

Este software é fornecido "como está", sem garantias de qualquer tipo. Alterações no sistema operacional podem afetar a estabilidade, a segurança e o funcionamento de outros programas. Use por sua conta e risco, depois de revisar o código e criar um backup do sistema.
