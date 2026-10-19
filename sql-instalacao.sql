-- ============================================================================
-- clinia.ai — INSTALAÇÃO COMPLETA DO SCHEMA
-- ============================================================================
--
-- Ficheiro gerado automaticamente. NÃO EDITAR À MÃO: as alterações perdem-se na
-- próxima geração. Editar os ficheiros em db/migrations e db/seed.
--
-- COMO USAR:
--   1. Abre o SQL Editor do teu projeto Supabase.
--   2. Cola TODO este ficheiro.
--   3. Corre. Demora alguns segundos.
--   4. No fim aparece um resumo com o que foi criado.
--
-- É seguro correr duas vezes: o script limpa as tabelas antes de as criar.
--
-- AVISO SOBRE OS DADOS EXISTENTES:
-- este script APAGA as tabelas do protótipo antigo (utentes, sessoes, agenda,
-- avaliacoes_mfr, diagnosticos_medicos, perfis, profissionais, clinicas) e
-- cria o schema novo no lugar. Se tiveres dados de utentes reais nessas tabelas,
-- FAZ UMA CÓPIA antes de correr isto:
--
--   create table public.copia_utentes as select * from public.utentes;
--   create table public.copia_sessoes as select * from public.sessoes;
--
-- Gerado em 2026-10-19T12:27:12.146Z
-- Administrador: support@clinia.live (7da45b31-2f88-4628-be59-e68262854c12)
--
-- ÁRVORE DE ORIGEM: codigo
--   Este ficheiro foi gerado pela árvore de código «codigo». Quando existem
--   várias cópias da árvore — uma por ambiente — é esta linha que diz qual delas
--   produziu este ficheiro. Sem ela, comparar dois ficheiros gerados é comparar
--   tamanhos à mão, que é o que se fez durante demasiado tempo.
-- ============================================================================

-- Garantir que os objetos ficam a pertencer ao dono do schema, para não voltar
-- a aparecer o erro "must be owner of table" que bloqueou o protótipo.
--
-- O schema "extensions" ENTRA NO search_path, e isso não é decoração: no
-- Supabase o pgcrypto (gen_random_bytes, digest) vive lá, e não em "public".
-- Sem ele, qualquer função que use essas primitivas sem qualificar o schema
-- rebenta a meio da instalação — e como corre tudo numa só transação, rebenta a
-- instalação INTEIRA. Foi exactamente o que aconteceu na clínica de ensaio:
-- "function gen_random_bytes(integer) does not exist", com 8 900 linhas já lidas.
set search_path = public, extensions;

begin;

-- As extensões, e onde ficam.
--
-- A versão anterior dizia "create extension if not exists pgcrypto;" sem
-- indicar o schema. Onde a extensão acaba depende do search_path em vigor, o
-- que tornava o resultado dependente de um detalhe invisível. Aqui o schema é
-- explícito, e o bloco exterior reporta ONDE cada extensão ficou — para que a
-- resposta apareça no fim da instalação em vez de se descobrir pelo erro.
do $$
declare
  v_onde text;
begin
  /* O schema "extensions" existe em qualquer projeto Supabase, mas criar a
     instalação noutro PostgreSQL não é hipótese teórica. */
  begin
    create schema if not exists extensions;
  exception when others then
    raise warning 'Não foi possível garantir o schema extensions (%).', sqlerrm;
  end;

  begin
    create extension if not exists pgcrypto with schema extensions;
    select n.nspname into v_onde
      from pg_extension e join pg_namespace n on n.oid = e.extnamespace
     where e.extname = 'pgcrypto';
    raise notice 'Extensão pgcrypto: % (necessária para gen_random_bytes e digest).', coalesce(v_onde, 'instalada');
  exception when others then
    raise warning 'Não foi possível criar a extensão pgcrypto (%). Sem ela, a geração de tokens de consentimento e a impressão digital das assinaturas não funcionam.', sqlerrm;
  end;

  begin
    create extension if not exists pg_trgm with schema extensions;
    raise notice 'Extensão pg_trgm: ok (pesquisa tolerante nos catálogos).';
  exception when others then
    raise warning 'Não foi possível criar a extensão pg_trgm (%). A pesquisa tolerante nos catálogos fica sem índice.', sqlerrm;
  end;

  begin
    create extension if not exists btree_gist with schema extensions;
    raise notice 'Extensão btree_gist: ok (restrições de exclusão da agenda).';
  exception when others then
    raise warning 'Não foi possível criar a extensão btree_gist (%).', sqlerrm;
  end;
end $$;

-- ============================================================================
-- PARTE 1 — ESQUEMA (núcleo multi-tenant + módulo MFR)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0001_extensoes_e_dominio.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0001 — Extensões, domínios e tipos
-- Alvo: PostgreSQL 15+ (Supabase)
-- Idempotente: pode ser corrida mais do que uma vez.
--
-- Regra de ouro desta migração: os tipos (enums) são a autoridade do que é
-- válido. Preferimos falhar na escrita a guardar texto livre que depois não
-- se consegue agregar. O blueprint pede "enums em vez de texto livre".
-- ============================================================================

-- pgcrypto: gen_random_uuid() nas chaves e digest() na impressão digital das
--          assinaturas dos atos.
-- pg_trgm:  índices de pesquisa tolerante nos catálogos (CIF, CID). O
--          to_tsvector não serve para índice porque não é IMMUTABLE — ver
--          migração 0005 para a explicação completa.
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- 0. Schema próprio para utilitários
-- ---------------------------------------------------------------------------
create schema if not exists clinia;

comment on schema clinia is
  'Funções utilitárias da plataforma clinia.ai (não exposto por PostgREST).';

-- ---------------------------------------------------------------------------
-- 1. Identidade e papéis
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.perfil_tipo as enum (
    'administrador',        -- dono/gestor da clínica, acesso total ao tenant
    'fisiatra',             -- médico de MFR: diagnóstico médico, MCDT, receituário
    'fisioterapeuta',       -- avaliação pelo movimento + CIF: diagnóstico funcional
    'osteopata',            -- módulo de osteopatia (fase seguinte)
    'terapeuta_ocupacional',
    'terapeuta_da_fala',
    'psicologo',
    'enfermeiro',
    'rececao',              -- agenda e admissões, sem acesso clínico
    'gestao',               -- financeiro/relatórios, sem acesso clínico
    'utente',               -- portal do utente (só os seus dados)
    'socio'                 -- dono de parte da clínica; capacidade de administrador
  );
exception when duplicate_object then null; end $$;

/* ---------------------------------------------------------------------------
   PORQUE NÃO EXISTE UM PAPEL `socio`
   ---------------------------------------------------------------------------
   Pediram um papel «Sócio» no seletor. A tentação é acrescentar o valor a este
   enum. Não se fez, e a razão é concreta: o PostgreSQL recusa usar um valor de
   enum na MESMA transação em que ele é criado — «unsafe use of new value "socio"
   of enum type perfil_tipo» — e o ficheiro de instalação corre TODO dentro de
   uma transação, tanto no SQL Editor do Supabase como no teste que o valida.
   Acrescentar o valor aqui e usá-lo numa política ou numa função era garantir
   que a instalação falhava a meio.

   A alternativa seria pôr o valor numa migração e usá-lo na seguinte, o que
   funciona no teste (que corre por ficheiro) e FALHA no SQL Editor (que corre
   tudo de uma vez). Fazer uma coisa que passa nos testes e falha na mão do
   utilizador é pior do que não a fazer.

   O que ficou: «Sócio» é uma ETIQUETA no cliente para o papel `gestao`, que já
   tem exatamente as capacidades certas — entra em `e_admin()` (configura a
   clínica e a visibilidade) e NÃO entra em `e_clinico()` (ser dono não dá
   competência clínica). Quem for sócio E tratar doentes tem o papel clínico, e
   isso está certo: o papel diz o que a pessoa faz, e uma pessoa faz uma coisa.

   Fica registado para não ser tentado outra vez sem se saber isto.
   --------------------------------------------------------------------------- */

-- ---------------------------------------------------------------------------
-- 2. Especialidades / módulos de ato
--    A especialidade entra como DADO (JSON Schema do módulo), não como tabela
--    nova. Este enum existe só para roteamento e permissões.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.especialidade as enum (
    'mfr',                  -- medicina física e de reabilitação (1.º módulo)
    'osteopatia',
    'pediatrico',
    'gastro',
    'orl',
    'pneumo',
    'uro',
    'gineco'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 3. Utentes
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.utente_tipo as enum (
    'adulto',
    'pediatrico',
    'senior'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.consentimento_tipo as enum (
    'tratamento',           -- consentimento informado para tratamento
    'dados_pessoais',       -- RGPD: tratamento de dados de saúde (art. 9)
    'partilha_medica',      -- partilha com médico assistente / MCDT
    'imagem',               -- captura e uso de imagem/vídeo
    'comunicacoes'          -- contacto para marcações
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 4. Episódio de cuidados — a espinha dorsal do processo clínico
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.episodio_estado as enum (
    'aberto',
    'em_tratamento',
    'suspenso',
    'alta',
    'desistiu',
    'encaminhado'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.episodio_motivo as enum (
    'lesao_aguda',
    'dor_cronica',
    'pos_cirurgico',
    'reabilitacao_neurologica',
    'reabilitacao_cardiorrespiratoria',
    'prevencao',
    'segunda_opiniao',
    'outro'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 5. Diagnóstico — DOIS diagnósticos coexistem no mesmo episódio (entrada #001)
--    O CIF é partilhado; o que distingue os perfis é o OBJETIVO do diagnóstico.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.diagnostico_tipo as enum (
    'funcional',            -- fisioterapeuta: movimento + CIF
    'medico',               -- fisiatra: fisiopatológico + CID, puxa MCDT
    'diferencial'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.diagnostico_estado as enum (
    'suspeito',
    'provisorio',
    'confirmado',
    'excluido',
    'resolvido'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 6. Classificações — CIF tem qualificador; o qualificador é o que dá
--    granularidade clínica. Um código sem qualificador é quase inútil.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.cif_qualificador as enum (
    '0',    -- sem deficiência (0-4%)
    '1',    -- deficiência ligeira (5-24%)
    '2',    -- deficiência moderada (25-49%)
    '3',    -- deficiência grave (50-95%)
    '4',    -- deficiência completa (96-100%)
    '8',    -- não especificado
    '9'     -- não aplicável
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 7. Os três vetores — Dor · Movimento · Função
--    A dor caracteriza-se pela ORIGEM (biopsicossocial), não só pela
--    intensidade. "Nem sempre há dor; pode ser sinal ou proteção."
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.dor_origem as enum (
    'nociceptiva',          -- estrutural: lesão/trauma, mecânica
    'neuropatica',          -- neural / neurofisiológica
    'nociplastica',         -- central: sensibilização, mecanismo de proteção
    'psicossomatica',       -- psicológica / fatores psicossociais
    'mista',
    'sem_dor'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.dor_padrao_temporal as enum (
    'continua',
    'intermitente',
    'mecanica',             -- piora com carga, alivia com repouso
    'inflamatoria',         -- rigidez matinal, melhora com movimento
    'noturna',
    'a_esforco'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 8. Motor de atos e agenda
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.ato_tipo as enum (
    'consulta',             -- primeira consulta médica ou de fisioterapia
    'avaliacao',            -- avaliação estruturada dos 3 vetores
    'sessao',               -- sessão de tratamento (SOAP)
    'procedimento',         -- ato técnico (agulhamento seco, ondas de choque...)
    'reavaliacao',          -- reavaliação intercalar
    'nota_clinica',         -- nota livre
    'contacto',             -- telefonema, email, teleconsulta
    'alta'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.agendamento_estado as enum (
    'marcado',
    'confirmado',
    'em_sala',
    'realizado',
    'falta',                -- não compareceu
    'desmarcado',
    'cancelado'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.ato_estado as enum (
    'rascunho',
    'assinado',
    'retificado'            -- corrigido após assinatura; o original fica
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 9. Sessão — o formato SOAP é o que o Pedro usa? Está em aberto na base de
--    conhecimento. O schema suporta SOAP sem obrigar a ele: os quatro campos
--    são opcionais e a nota livre está sempre disponível.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.sessao_resposta as enum (
    'melhor',
    'igual',
    'pior',
    'flutuante'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 10. Plano — objetivo é ATIVIDADE DO UTENTE, alta ligada a ela (entrada #003)
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.objetivo_tipo as enum (
    'atividade_utente',     -- o que a pessoa QUER voltar a fazer (foco principal)
    'deficiencia',          -- recuperar ADM/força (meio, não fim)
    'participacao',         -- voltar ao trabalho, ao desporto, à vida social
    'educacao',             -- autogestão, compreensão da dor
    'prevencao'             -- evitar recidiva
  );
exception when duplicate_object then null; end $$;


do $$ begin
  create type public.objetivo_estado as enum (
    'em_curso',
    'atingido',
    'parcialmente_atingido',
    'nao_atingido',
    'abandonado'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 11. Requisições (MCDT / terapias) e receituário
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.requisicao_tipo as enum (
    'mcdt_imagiologia',
    'mcdt_analises',
    'mcdt_estudo_neurofisiologico',   -- EMG, ENMG, potenciais evocados
    'mcdt_estudo_funcional',          -- prova de esforço, espirometria, marcha
    'consulta_especialidade',
    'terapia',                        -- fisioterapia, TO, fala, psicologia
    'ajuda_tecnica',
    'outro'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.requisicao_estado as enum (
    'rascunho',
    'emitida',
    'enviada',
    'realizada',
    'resultado_recebido',
    'cancelada',
    'sem_resposta'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.prescricao_tipo as enum (
    'medicacao',
    'ajuda_tecnica',        -- ortótese, canadianas, cadeira, colchão
    'meio_auxiliar_de_marcha',
    'terapia',
    'analitica',
    'outro'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 12. Notas, media, relatórios e auditoria
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.relatorio_tipo as enum (
    'nota_clinica',
    'relatorio_alta',
    'relatorio_medico_legal',
    'relatorio_seguradora',
    'carta_medico_assistente',
    'declaracao_presenca',
    'outro'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.relatorio_estado as enum (
    'rascunho',
    'final',
    'assinado',
    'entregue'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.audit_operacao as enum (
    'insert',
    'update',
    'delete',
    'select_sensivel',      -- leitura de dados de saúde: registada por RGPD
    'login',
    'logout',
    'exportacao'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 13. Função genérica de updated_at
-- ---------------------------------------------------------------------------
create or replace function clinia.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 14. Minutos -> interval, marcado IMMUTABLE
--
-- Porque é preciso: a agenda tem uma constraint de exclusão que impede
-- sobreposições do mesmo profissional, e uma constraint de exclusão exige
-- funções IMMUTABLE na expressão. O make_interval() nativo é apenas STABLE e o
-- PostgreSQL recusa-o com "functions in index expression must be marked
-- IMMUTABLE".
--
-- Porque é honesto marcá-la immutable: converter um número de minutos num
-- intervalo é aritmética pura. O make_interval nativo é STABLE por uma questão
-- de estilo de formatação do intervalo, não por o valor depender de contexto.
-- A sobreposição de horários não pode depender de formatação.
-- ---------------------------------------------------------------------------
create or replace function clinia.minutos_intervalo(p_minutos integer)
returns interval
language sql
immutable
parallel safe
as $$
  select make_interval(mins => coalesce(p_minutos, 0));
$$;

comment on function clinia.minutos_intervalo(integer) is
  'Converte minutos num interval. IMMUTABLE de propósito: é usado na constraint de exclusão da agenda.';

comment on function clinia.set_updated_at() is
  'Trigger BEFORE UPDATE: mantém updated_at coerente sem depender do cliente.';


-- ----------------------------------------------------------------------------
-- 0001b_perfil_socio.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 0001b_perfil_socio.sql
-- ============================================================================
--
-- O PAPEL `socio`, ACRESCENTADO AO ENUM `perfil_tipo`.
--
-- PORQUE É UM FICHEIRO PRÓPRIO, E NÃO UM PARÁGRAFO DO 0001
-- ----------------------------------------------------------------------------
-- O PostgreSQL recusa usar um valor de enum na MESMA transação em que ele foi
-- acrescentado:
--
--   unsafe use of new value "socio" of enum type perfil_tipo
--
-- O ficheiro 0001 cria o tipo; o 0022 usa o `socio`. Se o `add value` estivesse
-- no 0001, e o 0001 e o 0022 corressem na mesma transação (é o que os testes
-- fazem, um ficheiro por vez), o erro aparecia. Num ficheiro separado, cada um
-- tem a sua transação e o valor já está consolidado quando o 0022 o usa.
--
-- A ORIGEM DO PROBLEMA
-- ----------------------------------------------------------------------------
-- O valor `socio` nunca era acrescentado em lado nenhum. O 0001 cria
-- `perfil_tipo` sem ele, e esse bloco está protegido por
-- `exception when duplicate_object then null` — numa base de dados onde o tipo
-- já exista, o `create type` não faz nada e o `socio` nunca aparece. O sintoma
-- era um erro que não aponta para a causa:
--
--   invalid input value for enum perfil_tipo: "socio"
-- ============================================================================

do $$ begin
  alter type public.perfil_tipo add value if not exists 'socio';
exception when others then null; end $$;


-- ----------------------------------------------------------------------------
-- 0002_tenant_identidade.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0002 — Tenant, identidade e pessoas
--
-- Multi-tenant: clinica_id em todas as tabelas de dados (padrão MYMW).
-- Distinção importante:
--   perfis        = CONTAS (login). id = auth.users.id. Uma por pessoa que entra.
--   profissionais = DIRETÓRIO clínico. Inclui quem não tem login (ex.: médico
--                   prescritor externo que aparece no dropdown e assina receitas).
-- A FK de profissionais -> perfis é ON DELETE SET NULL de propósito: se a conta
-- de um profissional for apagada, o registo clínico que ele assinou NÃO pode
-- ficar órfão nem ser apagado. Fica o nome, perde-se o login.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Limpeza das tabelas desta migração
--
-- PORQUE ISTO É NECESSÁRIO: `create table if not exists` NÃO altera uma tabela
-- que já exista. Num projeto que teve um protótipo anterior, `clinicas`,
-- `perfis` e `profissionais` já existem — com OUTRA estrutura. O
-- `if not exists` passa ao lado, a tabela fica com as colunas antigas, e a
-- migração rebenta mais à frente com um erro enganador:
--
--   ERROR: 42703: column "perfil_id" does not exist
--   LINE 532: on public.profissionais (perfil_id) where perfil_id is not null;
--
-- Pior do que rebentar seria não rebentar: tabelas a existir com a estrutura
-- errada dão falhas dispersas, difíceis de atribuir a esta causa.
--
-- O cascade é intencional: leva consigo os objetos dependentes (chaves
-- estrangeiras, vistas, gatilhos) que de outro modo impediriam a remoção. As
-- migrações seguintes recriam tudo pela ordem correta.
--
-- ESTAS TABELAS NÃO GUARDAM DADOS CLÍNICOS DE UTENTES: são de configuração,
-- contas e diretório clínico. O bootstrap (db/seed/0004) recria a clínica e o
-- administrador. Se tiveres utentes reais no protótipo, copia-os antes — está
-- explicado em docs/publicar.md.
-- ---------------------------------------------------------------------------
drop table if exists public.profissionais cascade;
drop table if exists public.perfis cascade;
drop table if exists public.clinicas cascade;

-- ---------------------------------------------------------------------------
-- 1. Clínicas (tenant)
-- ---------------------------------------------------------------------------
create table if not exists public.clinicas (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  nome_curto    text,
  nif           text,
  email         text,
  telefone      text,
  morada        text,
  codigo_postal text,
  localidade    text,
  pais          text not null default 'PT',
  regiao_dados  text not null default 'eu-west-1',   -- alojamento UE (RGPD art. 9)
  especialidades public.especialidade[] not null default array['mfr']::public.especialidade[],
  configuracoes jsonb not null default '{}'::jsonb,  -- fuso, duração padrão de sessão, logotipo...
  ativo         boolean not null default true,
  arquivado_em  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint clinicas_nome_nao_vazio check (length(btrim(nome)) > 0)
);

comment on table public.clinicas is
  'Tenant. Todo o dado clínico é isolado por clinica_id via RLS.';

-- ---------------------------------------------------------------------------
-- 2. Perfis (contas de utilizador)
-- ---------------------------------------------------------------------------
create table if not exists public.perfis (
  id             uuid primary key references auth.users(id) on delete cascade,
  clinica_id     uuid references public.clinicas(id) on delete set null,
  nome           text not null,
  email          text,
  telefone       text,
  perfil         public.perfil_tipo not null default 'fisioterapeuta',
  numero_cedula  text,                                  -- cédula profissional
  especialidade  public.especialidade not null default 'mfr',
  cor_agenda     text,                                  -- cor na agenda partilhada
  ativo          boolean not null default true,
  ultimo_acesso  timestamptz,
  preferencias   jsonb not null default '{}'::jsonb,     -- atalhos, densidade de UI...
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint perfis_nome_nao_vazio check (length(btrim(nome)) > 0)
);

create index if not exists idx_perfis_clinica on public.perfis (clinica_id);
create index if not exists idx_perfis_perfil  on public.perfis (perfil);

drop trigger if exists t_perfis_updated_at on public.perfis;
create trigger t_perfis_updated_at
  before update on public.perfis
  for each row execute function clinia.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Profissionais (diretório clínico)
-- ---------------------------------------------------------------------------
create table if not exists public.profissionais (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid references public.clinicas(id) on delete set null,
  perfil_id      uuid references public.perfis(id) on delete set null,
  nome           text not null,
  perfil         public.perfil_tipo,
  especialidade  public.especialidade not null default 'mfr',
  numero_cedula  text,
  email          text,
  telefone       text,
  cor_agenda     text,
  interno        boolean not null default true,   -- false = prescritor/externo
  prescritor     boolean not null default false,  -- pode assinar requisições/receitas
  ativo          boolean not null default true,
  notas          text,
  arquivado_em   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint profissionais_nome_nao_vazio check (length(btrim(nome)) > 0)
);

-- Uma conta só pode originar um registo de diretório.
create unique index if not exists uq_profissionais_perfil
  on public.profissionais (perfil_id) where perfil_id is not null;
create index if not exists idx_profissionais_clinica on public.profissionais (clinica_id);
create index if not exists idx_profissionais_ativo
  on public.profissionais (clinica_id, ativo) where arquivado_em is null;

drop trigger if exists t_profissionais_updated_at on public.profissionais;
create trigger t_profissionais_updated_at
  before update on public.profissionais
  for each row execute function clinia.set_updated_at();

comment on table public.profissionais is
  'Diretório de profissionais (internos com login e externos/prescritores sem login).';

-- ---------------------------------------------------------------------------
-- 4. Espelho perfis -> profissionais
--    Mantém os dropdowns e as relações de agenda/diagnóstico sempre coerentes.
--    SEGURANÇA: security definer para não depender das políticas RLS do
--    utilizador que está a criar a conta (senão o admin não consegue convidar).
-- ---------------------------------------------------------------------------
create or replace function clinia.sync_profissional_de_perfil()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
begin
  -- Perfis que não exercem: não entram no diretório clínico.
  if new.perfil in ('utente', 'rececao', 'gestao') then
    update public.profissionais
       set ativo = false
     where perfil_id = new.id;
    return new;
  end if;

  insert into public.profissionais as p (
    clinica_id, perfil_id, nome, perfil, especialidade, numero_cedula,
    email, telefone, cor_agenda, interno, prescritor, ativo
  ) values (
    new.clinica_id, new.id, new.nome, new.perfil, new.especialidade, new.numero_cedula,
    new.email, new.telefone, new.cor_agenda, true,
    -- Só quem pode prescrever: fisiatra (e administrador, por delegação).
    new.perfil in ('fisiatra', 'administrador'),
    coalesce(new.ativo, true)
  )
  -- O índice único de perfil_id é parcial; a inferência tem de repetir o predicado.
  on conflict (perfil_id) where perfil_id is not null do update
     set clinica_id    = excluded.clinica_id,
         nome          = excluded.nome,
         perfil        = excluded.perfil,
         especialidade = excluded.especialidade,
         numero_cedula = excluded.numero_cedula,
         email         = excluded.email,
         telefone      = excluded.telefone,
         cor_agenda    = excluded.cor_agenda,
         prescritor    = excluded.prescritor,
         ativo         = coalesce(new.ativo, true),
         updated_at    = now();

  return new;
end $$;

comment on function clinia.sync_profissional_de_perfil() is
  'Espelha perfis no diretório profissionais (entrada #002: dropdowns coerentes).';

drop trigger if exists t_perfis_sync_profissional on public.perfis;
create trigger t_perfis_sync_profissional
  after insert or update of nome, perfil, clinica_id, ativo, especialidade,
                              numero_cedula, email, telefone, cor_agenda
  on public.perfis
  for each row execute function clinia.sync_profissional_de_perfil();

-- ---------------------------------------------------------------------------
-- 5. Nota de compatibilidade com o protótipo
--    O SQL da app Qwen tinha public.profissionais(id = perfis.id). Aqui o id é
--    próprio e o vínculo é perfil_id. Ver docs/arquitetura.md para o mapa de
--    migração das 8 tabelas do protótipo para este schema.
-- ---------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- 0003_utentes.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0003 — Utentes e consentimentos (RGPD)
--
-- Dados de saúde são categoria especial (RGPD art. 9). Por isso:
--   · consentimentos são tabela própria, tipados e versionados (não um booleano);
--   · o consentimento de tratamento e de dados é requisito de negócio, não
--     decoração — a app bloqueia o ato clínico sem ele (regra na migração 0011);
--   · nada se apaga fisicamente: arquivado_em + ON DELETE RESTRICT.
-- ============================================================================

-- Referência antecipada: utentes aponta para o episódio em curso e episódios
-- apontam para utentes. Resolvemos a circularidade com um placeholder, que é
-- substituído a seguir por um drop limpo (a tabela ainda está vazia).
create table if not exists public.episodios (id uuid primary key);

-- ---------------------------------------------------------------------------
-- 0. Limpeza das tabelas desta migração
--
-- Mesma razão da migração 0002: `create table if not exists` não altera uma
-- tabela que já exista. O protótipo anterior tinha `utentes` com outra
-- estrutura, e sem esta remoção a tabela ficava com as colunas antigas — e as
-- migrações seguintes falhavam com erros que não apontavam para aqui.
--
-- ATENÇÃO: `utentes` guarda dados de pessoas. Se tiveres utentes reais no
-- protótipo, copia-os ANTES de correr isto (ver docs/publicar.md).
-- ---------------------------------------------------------------------------
drop table if exists public.utentes cascade;
drop sequence if exists public.utente_numero_seq cascade;

-- ---------------------------------------------------------------------------
-- 1. Utentes
-- ---------------------------------------------------------------------------
create sequence if not exists public.utente_numero_seq start 1;

create table if not exists public.utentes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  numero_utente     integer not null default nextval('public.utente_numero_seq'),
  nome              text not null,
  nome_preferido    text,
  data_nascimento   date,
  tipo              public.utente_tipo not null default 'adulto',
  sexo              text,                                   -- livre, sem valor clínico obrigatório
  nif               text,
  numero_sns        text,
  numero_utente_sns text,
  email             text,
  telemovel         text,
  telefone          text,
  morada            text,
  codigo_postal     text,
  localidade        text,
  pais              text not null default 'PT',

  -- Contexto clínico de segurança: alergias e alertas aparecem SEMPRE à frente
  -- de quem vai tratar. Um alerta escondido é um erro clínico.
  alertas           text[] not null default '{}',
  alergias          text[] not null default '{}',
  antecedentes      text,
  medicacao_habitual text,

  -- Enquadramento administrativo
  seguradora        text,
  numero_apolice    text,
  entidade_pagadora text,
  profissional_referenciador_id uuid references public.profissionais(id) on delete set null,

  -- Episódio em curso: atalho para o ecrã, evita um JOIN em cada abertura de ficha.
  episodio_atual_id uuid,

  notas             text,
  ativo             boolean not null default true,
  arquivado_em      timestamptz,
  arquivado_motivo  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint utentes_nome_nao_vazio check (length(btrim(nome)) > 0),
  constraint utentes_numero_unico   unique (numero_utente),
  constraint utentes_nascimento_sanidade
    check (data_nascimento is null or data_nascimento between date '1900-01-01' and current_date)
);

create index if not exists idx_utentes_clinica  on public.utentes (clinica_id);
create index if not exists idx_utentes_nome     on public.utentes (clinica_id, lower(nome));
create index if not exists idx_utentes_ativos
  on public.utentes (clinica_id) where arquivado_em is null;
create index if not exists idx_utentes_telemovel on public.utentes (telemovel);

drop trigger if exists t_utentes_updated_at on public.utentes;
create trigger t_utentes_updated_at
  before update on public.utentes
  for each row execute function clinia.set_updated_at();

comment on column public.utentes.alertas is
  'Alertas clínicos de segurança mostrados em destaque no cabeçalho da ficha.';
comment on column public.utentes.episodio_atual_id is
  'Episódio de cuidados em curso. FK adicionada a seguir a episodios existir.';

-- ---------------------------------------------------------------------------
-- 2. Contactos do utente (familiares, cuidadores, médicos externos)
--    O blueprint prevê o portal do utente; os cuidadores são quem muitas vezes
--    traz o doente pediátrico ou o sénior. São dados de contacto, não contas.
-- ---------------------------------------------------------------------------
create table if not exists public.utente_contactos (
  id           uuid primary key default gen_random_uuid(),
  clinica_id   uuid not null references public.clinicas(id) on delete restrict,
  utente_id    uuid not null references public.utentes(id) on delete restrict,
  nome         text not null,
  relacao      text,                       -- cônjuge, filho, cuidador, médico assistente
  telefone     text,
  email        text,
  principal    boolean not null default false,
  pode_contactar boolean not null default true,
  notas        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint utente_contactos_nome_nao_vazio check (length(btrim(nome)) > 0)
);

create index if not exists idx_utente_contactos_utente on public.utente_contactos (utente_id);

-- Só um contacto principal por utente.
create unique index if not exists uq_utente_contacto_principal
  on public.utente_contactos (utente_id) where principal;

drop trigger if exists t_utente_contactos_updated_at on public.utente_contactos;
create trigger t_utente_contactos_updated_at
  before update on public.utente_contactos
  for each row execute function clinia.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Consentimentos (RGPD art. 9)
--    Nunca se apaga nem se atualiza um consentimento: revoga-se e cria-se um
--    novo. O histórico de consentimento é prova legal.
-- ---------------------------------------------------------------------------
create table if not exists public.consentimentos (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas(id) on delete restrict,
  utente_id      uuid not null references public.utentes(id) on delete restrict,
  tipo           public.consentimento_tipo not null,
  versao_texto   text not null default 'v1',
  concedido      boolean not null,
  concedido_em   timestamptz not null default now(),
  revogado_em    timestamptz,
  revogado_motivo text,
  -- Quem consentiu pode não ser o utente (menor, incapacitado): registamos isso.
  concedido_por  text,
  qualidade      text,                       -- próprio, representante legal, tutor
  testemunha     text,
  documento_url  text,                       -- digitalização assinada (Storage UE)
  registado_por  uuid references public.perfis(id) on delete set null,
  created_at     timestamptz not null default now(),
  constraint consentimentos_revogacao_coerente
    check ((revogado_em is null) or (revogado_em >= concedido_em))
);

create index if not exists idx_consentimentos_utente on public.consentimentos (utente_id, tipo);
create index if not exists idx_consentimentos_validos
  on public.consentimentos (utente_id, tipo)
  where concedido and revogado_em is null;

comment on table public.consentimentos is
  'Consentimentos RGPD. Append-only: revoga-se, nunca se apaga (prova legal).';

-- ---------------------------------------------------------------------------
-- 4. Utilitário: o utente tem consentimento válido deste tipo?
--    Usado pela app e (mais tarde) como guarda de negócio nos atos clínicos.
-- ---------------------------------------------------------------------------
create or replace function clinia.tem_consentimento(p_utente uuid, p_tipo public.consentimento_tipo)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.consentimentos c
     where c.utente_id = p_utente
       and c.tipo = p_tipo
       and c.concedido
       and c.revogado_em is null
  );
$$;

comment on function clinia.tem_consentimento(uuid, public.consentimento_tipo) is
  'true se existe consentimento válido (concedido e não revogado) para o utente.';


-- ----------------------------------------------------------------------------
-- 0004_episodios_diagnosticos.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0004 — Episódio de cuidados e diagnósticos
--
-- O EPISÓDIO é a espinha dorsal que faltava ao protótipo. Tudo o que é clínico
-- (avaliações, planos, sessões, requisições, relatórios) pendura-se no episódio,
-- não no utente. Sem episódio não há processo de cuidados, não há alta, não há
-- como comparar o antes e o depois da mesma queixa.
--
-- Regra de negócio: um utente pode ter vários episódios ao longo da vida, mas
-- apenas UM episódio ativo por especialidade em cada momento.
-- ============================================================================

-- Substitui o placeholder criado na migração 0003 (ainda vazio por construção).
drop table if exists public.episodios cascade;

create sequence if not exists public.episodio_numero_seq start 1;

create table if not exists public.episodios (
  id                    uuid primary key default gen_random_uuid(),
  clinica_id            uuid not null references public.clinicas(id) on delete restrict,
  utente_id             uuid not null references public.utentes(id) on delete restrict,
  numero_episodio       integer not null default nextval('public.episodio_numero_seq'),

  -- O que traz a pessoa e onde nos situamos no processo
  motivo_principal      public.episodio_motivo not null default 'outro',
  motivos_secundarios   text[] not null default '{}',
  especialidade         public.especialidade not null default 'mfr',
  estado                public.episodio_estado not null default 'aberto',
  data_inicio           date not null default current_date,
  data_fim              date,

  -- Queixa principal nas palavras do próprio utente. Não é diagnóstico: é o
  -- ponto de partida e a frase a que voltamos para avaliar se houve ganho.
  queixa_principal      text,
  historia_doenca       text,

  -- A FUNÇÃO é o vetor que define o objetivo e o critério de alta (entrada #003).
  -- Guardado no episódio porque é o enquadramento de todo o processo, não de
  -- uma sessão. As atividades concretas vivem em plano_objetivos.
  expectativa_utente    text,

  -- Equipa
  profissional_principal_id uuid references public.profissionais(id) on delete set null,
  medico_assistente     text,
  origem_encaminhamento text,

  -- Desfecho
  motivo_alta           text,
  resumo_alta           text,

  -- Encerramento por inatividade, com a porta aberta a reabrir
  reaberto_de_id        uuid references public.episodios(id) on delete set null,

  notas                 text,
  arquivado_em          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid references public.perfis(id) on delete set null,
  updated_by            uuid references public.perfis(id) on delete set null,

  constraint episodios_numero_unico_por_clinica unique (clinica_id, numero_episodio),
  constraint episodios_datas_coerentes
    check (data_fim is null or data_fim >= data_inicio),
  constraint episodios_alta_tem_data
    check (estado <> 'alta' or data_fim is not null)
);

create index if not exists idx_episodios_clinica  on public.episodios (clinica_id);
create index if not exists idx_episodios_utente   on public.episodios (utente_id, data_inicio desc);
create index if not exists idx_episodios_estado   on public.episodios (clinica_id, estado);
create index if not exists idx_episodios_abertos
  on public.episodios (utente_id, especialidade)
  where estado in ('aberto', 'em_tratamento', 'suspenso');
create index if not exists idx_episodios_prof     on public.episodios (profissional_principal_id);

drop trigger if exists t_episodios_updated_at on public.episodios;
create trigger t_episodios_updated_at
  before update on public.episodios
  for each row execute function clinia.set_updated_at();

comment on table public.episodios is
  'Processo de cuidados. Contexto obrigatório de tudo o que é clínico.';
comment on column public.episodios.queixa_principal is
  'Nas palavras do utente. Referência para avaliar ganho funcional real.';

-- Agora sim, a FK circular de utentes -> episódio em curso.
alter table public.utentes
  drop constraint if exists utentes_episodio_atual_fk;
alter table public.utentes
  add constraint utentes_episodio_atual_fk
  foreign key (episodio_atual_id) references public.episodios(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Integridade: apenas um episódio ativo por utente e especialidade.
-- ---------------------------------------------------------------------------
create unique index if not exists uq_episodio_ativo_por_especialidade
  on public.episodios (utente_id, especialidade)
  where estado in ('aberto', 'em_tratamento', 'suspenso');

-- ---------------------------------------------------------------------------
-- 2. DIAGNÓSTICOS — dois diagnósticos coexistem no mesmo episódio (entrada #001)
--    · funcional  (fisioterapeuta): pelo movimento + CIF
--    · medico     (fisiatra):       fisiopatológico + CID, puxa MCDT
--    O CIF é PARTILHADO: não pertence a nenhum dos perfis.
-- ---------------------------------------------------------------------------
create table if not exists public.diagnosticos (
  id                 uuid primary key default gen_random_uuid(),
  clinica_id         uuid not null references public.clinicas(id) on delete restrict,
  episodio_id        uuid not null references public.episodios(id) on delete restrict,
  utente_id          uuid not null references public.utentes(id) on delete restrict,

  tipo               public.diagnostico_tipo not null,
  estado             public.diagnostico_estado not null default 'provisorio',

  -- Classificação médica (CID/ICD). O CID-10 é o usado em Portugal; guardamos o
  -- sistema para permitir ICD-11 sem migração.
  codigo_cid         text,
  sistema_cid        text not null default 'CID-10',
  descricao_medica   text,

  -- Classificação funcional. O CIF pode ser multi-código com qualificador;
  -- a lista estruturada vive em episodio_cif e aqui fica o resumo legível.
  codigo_cif         text,
  descricao_funcional text,

  -- Etiologia / mecanismo, alinhado com a dor biopsicossocial
  mecanismo          public.dor_origem,
  regiao_anatomica   text,
  lateralidade       text,

  -- O diagnóstico médico puxa meios complementares de diagnóstico
  mcdt_solicitados   text[] not null default '{}',

  -- Rastreabilidade: quem afirmou isto e com que grau de certeza
  profissional_id    uuid references public.profissionais(id) on delete set null,
  data_diagnostico   date not null default current_date,
  fundamentacao      text,               -- testes, achados, raciocínio clínico
  notas              text,

  -- Um diagnóstico retificado não se apaga: cria-se outro e referencia-se
  retifica_id        uuid references public.diagnosticos(id) on delete set null,
  arquivado_em       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- Diagnóstico médico sem CID é aceitável em rascunho, mas exigimos coerência
  -- mínima: tipo 'medico' não pode vir sem descrição.
  constraint diagnosticos_descricao_obrigatoria
    check (
      (tipo = 'medico'    and (descricao_medica is not null or codigo_cid is not null))
      or
      (tipo = 'funcional' and (descricao_funcional is not null or codigo_cif is not null))
      or
      tipo = 'diferencial'
    )
);

create index if not exists idx_diagnosticos_episodio on public.diagnosticos (episodio_id, tipo);
create index if not exists idx_diagnosticos_utente   on public.diagnosticos (utente_id);
create index if not exists idx_diagnosticos_cid      on public.diagnosticos (codigo_cid);
create index if not exists idx_diagnosticos_cif      on public.diagnosticos (codigo_cif);

drop trigger if exists t_diagnosticos_updated_at on public.diagnosticos;
create trigger t_diagnosticos_updated_at
  before update on public.diagnosticos
  for each row execute function clinia.set_updated_at();

comment on table public.diagnosticos is
  'Diagnóstico funcional (movimento+CIF) e médico (fisiopatológico+CID) no mesmo episódio.';

-- ---------------------------------------------------------------------------
-- 3. CIF POR EPISÓDIO — classificação partilhada, multi-código com qualificador
--    O qualificador é o que dá valor clínico: "b7102" diz pouco, "b7102.2" diz
--    deficiência moderada da função sexual... e é isso que se pode medir e
--    comparar ao longo do tempo.
-- ---------------------------------------------------------------------------
create table if not exists public.episodio_cif (
  id              uuid primary key default gen_random_uuid(),
  clinica_id      uuid not null references public.clinicas(id) on delete restrict,
  episodio_id     uuid not null references public.episodios(id) on delete restrict,
  utente_id       uuid not null references public.utentes(id) on delete restrict,

  codigo          text not null,              -- ex.: b28013, d4500, s750
  qualificador    public.cif_qualificador,    -- 0-4, 8, 9
  -- Núcleo da CIF: função/estrutura (b/s), atividade (d), participação, ambiente (e)
  componente      text,                       -- b | s | d | e
  descricao       text,                       -- rótulo legível do código
  -- Para que serve este código no episódio: caracterizar, justificar, medir
  papel           text not null default 'caracterizacao',  -- caracterizacao | objetivo | barreira | facilitador
  avaliacao_inicial public.cif_qualificador,
  avaliacao_atual   public.cif_qualificador,
  notas           text,

  registado_por   uuid references public.profissionais(id) on delete set null,
  data_registo    date not null default current_date,
  arquivado_em    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint episodio_cif_codigo_formato
    check (codigo ~ '^[bsde][0-9]{1,5}$'),
  constraint episodio_cif_componente_coerente
    check (componente is null or componente = left(codigo, 1))
);

create index if not exists idx_episodio_cif_episodio on public.episodio_cif (episodio_id);
create index if not exists idx_episodio_cif_codigo   on public.episodio_cif (codigo);

drop trigger if exists t_episodio_cif_updated_at on public.episodio_cif;
create trigger t_episodio_cif_updated_at
  before update on public.episodio_cif
  for each row execute function clinia.set_updated_at();

comment on table public.episodio_cif is
  'CIF do episódio: multi-código com qualificador, partilhado por fisioterapeuta e fisiatra.';

-- ---------------------------------------------------------------------------
-- 4. Utilitário: episódio em curso do utente (usado pela app e pelos gatilhos)
-- ---------------------------------------------------------------------------
create or replace function clinia.episodio_ativo(p_utente uuid, p_especialidade public.especialidade default 'mfr')
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.id
    from public.episodios e
   where e.utente_id = p_utente
     and e.especialidade = p_especialidade
     and e.estado in ('aberto', 'em_tratamento', 'suspenso')
   order by e.data_inicio desc
   limit 1;
$$;

-- Mantém utentes.episodio_atual_id coerente sem o cliente ter de colaborar.
-- O atalho aponta para o episódio ativo mais recente; se não houver, fica a null
-- e a app sabe que o utente não tem processo aberto.
create or replace function clinia.sync_episodio_atual()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_utente uuid := coalesce(new.utente_id, old.utente_id);
begin
  update public.utentes u
     set episodio_atual_id = (
       select e.id
         from public.episodios e
        where e.utente_id = v_utente
          and e.arquivado_em is null
          and e.estado in ('aberto', 'em_tratamento', 'suspenso')
        order by e.data_inicio desc, e.created_at desc
        limit 1
     )
   where u.id = v_utente;
  return null;
end $$;

comment on function clinia.sync_episodio_atual() is
  'Trigger AFTER em episodios: mantém o atalho utentes.episodio_atual_id.';

drop trigger if exists t_episodios_sync_atual on public.episodios;
create trigger t_episodios_sync_atual
  after insert or delete or update of estado, arquivado_em on public.episodios
  for each row execute function clinia.sync_episodio_atual();


-- ----------------------------------------------------------------------------
-- 0005_classificacoes_e_anatomia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0005 — Classificações partilhadas e anatomia de referência
--
-- Entrada #001 da base de conhecimento: "o CIF é a Classificação Internacional
-- de Funcionalidade. A fisioterapeuta também o usa." O CIF vive no NÚCLEO e
-- serve os dois perfis. Estas tabelas são catálogo — não dados de utente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. CIF — Classificação Internacional de Funcionalidade (OMS)
--    O código sozinho diz pouco: o qualificador é o que mede.
-- ---------------------------------------------------------------------------
create table if not exists public.cif_catalogo (
  codigo        text primary key,
  componente    text not null,                  -- b | s | d | e
  capitulo      text,                           -- b1..b8, d1..d9
  descricao     text not null,
  descricao_curta text,
  -- Hierarquia do CIF: b280 > b2801 > b28013. Guardamos o pai para navegar.
  codigo_pai    text references public.cif_catalogo(codigo) on delete set null,
  nivel         smallint not null default 1,
  usa_qualificador boolean not null default true,
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint cif_catalogo_componente_valido check (componente in ('b','s','d','e')),
  constraint cif_catalogo_codigo_formato check (codigo ~ '^[bsde][0-9]{1,5}$')
);

create index if not exists idx_cif_catalogo_componente on public.cif_catalogo (componente, capitulo);
create index if not exists idx_cif_catalogo_pai        on public.cif_catalogo (codigo_pai);
-- Pesquisa por texto no seletor de CIF (o clínico escreve "dor", "marcha"...).
--
-- Porque trigramas e não to_tsvector: um índice de expressão exige uma função
-- IMMUTABLE, e to_tsvector('portuguese', ...) com a configuração escrita como
-- literal NÃO é immutable (depende do search_path e da configuração de texto).
-- O PostgreSQL recusa-o com "functions in index expression must be marked
-- IMMUTABLE". Podia contornar-se com uma função marcada immutable como
-- wrapper, mas isso seria mentir ao planeador sobre a imutabilidade.
--
-- Trigramas resolvem melhor o caso real: o clínico escreve fragmentos
-- ("march", "dorme") e não frases completas. O ILIKE '%...%' que a app usa
-- acelera exatamente com gin_trgm_ops.
create index if not exists idx_cif_catalogo_busca
  on public.cif_catalogo using gin (descricao gin_trgm_ops);
create index if not exists idx_cif_catalogo_codigo_busca
  on public.cif_catalogo using gin (codigo gin_trgm_ops);

comment on table public.cif_catalogo is
  'Catálogo CIF (OMS). Classificação partilhada por fisioterapeuta e fisiatra.';

-- ---------------------------------------------------------------------------
-- 2. CID — Classificação Internacional de Doenças
--    Em Portugal usa-se CID-10; o campo sistema permite ICD-11 sem migração.
-- ---------------------------------------------------------------------------
create table if not exists public.cid_catalogo (
  id            uuid primary key default gen_random_uuid(),
  sistema       text not null default 'CID-10',
  codigo        text not null,
  descricao     text not null,
  capitulo      text,
  grupo         text,
  -- Marcadores de utilidade clínica em MFR: sinalizam dor e uso em reabilitação.
  relevancia_mfr smallint not null default 0,   -- 0-3, para ordenar sugestões
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint cid_catalogo_unico unique (sistema, codigo)
);

-- Pesquisa tolerante (o clínico escreve "lombalgia", "M54", "coifa").
create index if not exists idx_cid_catalogo_busca
  on public.cid_catalogo using gin (descricao gin_trgm_ops);
create index if not exists idx_cid_catalogo_codigo_busca
  on public.cid_catalogo using gin (codigo gin_trgm_ops);
create index if not exists idx_cid_catalogo_relevancia on public.cid_catalogo (relevancia_mfr desc, codigo);

comment on table public.cid_catalogo is
  'Catálogo CID (CID-10 por omissão). Usado no diagnóstico médico do fisiatra.';

-- Agora que os catálogos existem, ligamos os diagnósticos a eles.
alter table public.diagnosticos
  drop constraint if exists diagnosticos_codigo_cif_fk;
alter table public.diagnosticos
  add constraint diagnosticos_codigo_cif_fk
  foreign key (codigo_cif) references public.cif_catalogo(codigo) on delete set null;

-- O CID é referenciado por (sistema, codigo), não por id: é assim que o clínico
-- pensa e evita joins desnecessários no ecrã.
create unique index if not exists uq_cid_catalogo_sistema_codigo
  on public.cid_catalogo (sistema, codigo);
alter table public.diagnosticos
  drop constraint if exists diagnosticos_codigo_cid_fk;
alter table public.diagnosticos
  add constraint diagnosticos_codigo_cid_fk
  foreign key (sistema_cid, codigo_cid) references public.cid_catalogo(sistema, codigo)
  on delete set null;

-- ---------------------------------------------------------------------------
-- 3. Regiões anatómicas e articulações
--    O movimento é o vetor de diagnóstico. Para o registar de forma estruturada
--    (e poder desenhar gráficos por articulação) precisamos de uma taxonomia
--    estável, não de texto livre.
-- ---------------------------------------------------------------------------
create table if not exists public.regioes_anatomicas (
  codigo      text primary key,               -- ex.: ombro_d, joelho_e
  nome        text not null,
  regiao_pai  text references public.regioes_anatomicas(codigo) on delete set null,
  lateralidade text,                          -- d | e | central
  ordem       smallint not null default 100,
  ativo       boolean not null default true
);

create table if not exists public.articulacoes (
  codigo          text primary key,           -- ex.: glenoumeral_d
  regiao_codigo   text references public.regioes_anatomicas(codigo) on delete set null,
  nome            text not null,
  -- Movimentos possíveis nesta articulação, para o formulário se montar sozinho
  movimentos      text[] not null default '{}',
  adm_normal      jsonb not null default '{}'::jsonb,  -- {"flexao": 180, "abducao": 180}
  ordem           smallint not null default 100,
  ativo           boolean not null default true
);

create index if not exists idx_articulacoes_regiao on public.articulacoes (regiao_codigo);

comment on table public.articulacoes is
  'Articulações e movimentos com ADM de referência, para entrada estruturada de movimento.';

-- ---------------------------------------------------------------------------
-- 4. Tipos de medição — o que se mede e como se chama
--    Uma medida sem unidade e sem direção de melhoria não serve para gráficos.
-- ---------------------------------------------------------------------------
create table if not exists public.tipos_medicao (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid references public.clinicas(id) on delete cascade,  -- null = global
  codigo            text not null,
  nome              text not null,
  categoria         text not null default 'movimento',
    -- movimento | forca | funcao | dor | amplitude | performance | antropometria | outro
  unidade           text,                     -- graus, kg, cm, segundos, repeticoes, metros
  decimais          smallint not null default 0,
  -- Direção de melhoria: subir ADM é bom, subir EVA é mau. Sem isto o gráfico mente.
  melhor_direcao    text not null default 'maior_melhor',
  min_valor         numeric,
  max_valor         numeric,
  permite_lado      boolean not null default false,   -- mede-se à direita e à esquerda?
  permite_bilateral boolean not null default false,
  articulacao_codigo text references public.articulacoes(codigo) on delete set null,
  movimento         text,                     -- flexao, extensao, abducao, rotacao_interna...
  ordem             smallint not null default 100,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  constraint tipos_medicao_direcao_valida
    check (melhor_direcao in ('maior_melhor','menor_melhor','neutro')),
  constraint tipos_medicao_intervalo_coerente
    check (min_valor is null or max_valor is null or min_valor <= max_valor)
);

-- Global (clinica_id null) ou específico da clínica.
create unique index if not exists uq_tipos_medicao_codigo_global
  on public.tipos_medicao (codigo) where clinica_id is null;
create unique index if not exists uq_tipos_medicao_codigo_clinica
  on public.tipos_medicao (clinica_id, codigo) where clinica_id is not null;
create index if not exists idx_tipos_medicao_categoria on public.tipos_medicao (categoria, ordem);

comment on column public.tipos_medicao.melhor_direcao is
  'Direção de melhoria clínica. Impede gráficos que sugerem melhoria quando há agravamento.';


-- ----------------------------------------------------------------------------
-- 0006_agenda_atos_escalas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0006 — Agenda, motor de atos e motor de escalas
--
-- O MOTOR DE ATOS é o coração modular do blueprint: o núcleo guarda o ato
-- genérico e a especialidade entra como DADOS (JSON Schema do módulo), não como
-- tabela nova. É isto que permite o gastro, ORL, pneumo, uro e gineco entrarem
-- depois sem tocar no núcleo.
--
-- Regra que sustenta o motor: o núcleo é responsável por QUEM, QUANDO, ONDE e
-- EM QUE CONTEXTO; o módulo é responsável pelo CONTEÚDO clínico. O JSONB do
-- módulo nunca é pesquisado às cegas — o que precisa de ser consultado e
-- agregado promove-se a tabela tipada (é o caso de todo o módulo MFR).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Remover as tabelas do protótipo que este schema substitui
--
-- O protótipo tinha `agenda`, `avaliacoes_mfr` e `diagnosticos_medicos`. Nenhuma
-- tem lugar no schema novo: a agenda passa a ser `agendamentos`, a avaliação MFR
-- é o conjunto tipado da migração 0007, e os diagnósticos são `diagnosticos`.
--
-- Sem esta remoção ficariam três tabelas órfãs, com dados antigos e sem RLS, a
-- confundir quem consulte a base de dados — e a fazer parecer que o schema novo
-- tem 40 tabelas em vez de 38.
--
-- ATENÇÃO: este é o ponto em que dados do protótipo são perdidos. Se tiveres
-- avaliações ou diagnósticos reais que valha a pena guardar, copia-os ANTES
-- (ver docs/publicar.md).
-- ---------------------------------------------------------------------------
drop table if exists public.avaliacoes_mfr cascade;
drop table if exists public.diagnosticos_medicos cascade;
-- `agenda` é tratada mais abaixo, onde a vista de compatibilidade é criada: aí
-- tem de se remover tanto a tabela do protótipo como a vista de execuções
-- anteriores, e é mais claro ter os dois comandos juntos.

-- ---------------------------------------------------------------------------
-- 1. Agenda
-- ---------------------------------------------------------------------------
create table if not exists public.agendamentos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete set null,
  profissional_id   uuid references public.profissionais(id) on delete set null,

  tipo              public.ato_tipo not null default 'sessao',
  especialidade     public.especialidade not null default 'mfr',
  estado            public.agendamento_estado not null default 'marcado',

  inicio            timestamptz not null,
  duracao_minutos   smallint not null default 45,
  sala              text,                       -- sala, box ou equipamento
  -- Encontros presenciais, teleconsulta ou domicílio mudam o que é preciso levar
  modalidade        text not null default 'presencial',   -- presencial | teleconsulta | domicilio

  motivo            text,
  notas             text,

  -- Série de tratamentos (ex.: 10 sessões, 2x/semana). Guardamos o laço entre
  -- irmãs para poder cancelar a série inteira de uma vez.
  serie_id          uuid,
  serie_indice      smallint,
  serie_total       smallint,

  -- Confirmações e faltas: alimentam a taxa de assiduidade, que é indicador
  -- de gestão e também clínico (faltas repetidas = abandono a caminho).
  confirmado_pelo_utente boolean not null default false,
  confirmado_em     timestamptz,
  lembrete_enviado_em timestamptz,
  motivo_falta      text,

  -- Quando o ato é registado, o agendamento fica ligado ao ato (e vice-versa)
  ato_id            uuid,

  -- Arquivar em vez de apagar: uma marcação desmarcada é histórico operacional
  -- (taxa de assiduidade, faltas repetidas) e não pode desaparecer. É também
  -- isto que o gatilho de sobreposição consulta para ignorar o que foi arquivado.
  arquivado_em      timestamptz,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,
  updated_by        uuid references public.perfis(id) on delete set null,

  constraint agendamentos_duracao_positiva check (duracao_minutos between 5 and 480),
  constraint agendamentos_modalidade_valida
    check (modalidade in ('presencial','teleconsulta','domicilio')),
  constraint agendamentos_serie_coerente
    check ((serie_id is null) = (serie_indice is null))
);

create index if not exists idx_agendamentos_clinica_data on public.agendamentos (clinica_id, inicio);
create index if not exists idx_agendamentos_utente       on public.agendamentos (utente_id, inicio desc);
create index if not exists idx_agendamentos_prof_data    on public.agendamentos (profissional_id, inicio);
create index if not exists idx_agendamentos_episodio     on public.agendamentos (episodio_id);
create index if not exists idx_agendamentos_estado       on public.agendamentos (clinica_id, estado, inicio);
create index if not exists idx_agendamentos_serie        on public.agendamentos (serie_id) where serie_id is not null;

drop trigger if exists t_agendamentos_updated_at on public.agendamentos;
create trigger t_agendamentos_updated_at
  before update on public.agendamentos
  for each row execute function clinia.set_updated_at();

comment on table public.agendamentos is
  'Agenda. Substitui a tabela agenda do protótipo (ver vista de compatibilidade no fim).';

-- Vista de compatibilidade: o protótipo lia public.agenda(data, hora, estado).
-- Mantém-se para não partir integrações existentes durante a transição.
--
-- A remoção prévia não pode ser feita com dois `drop ... if exists` em sequência,
-- porque o PostgreSQL distingue tipos e NENHUMA das ordens serve:
--
--   · `drop table if exists` sobre uma vista   → ERROR 42809
--       "agenda" is not a table / HINT: Use DROP VIEW to remove a view.
--   · `drop view if exists`  sobre uma tabela  → ERROR 42809
--       "agenda" is not a view  / HINT: Use DROP TABLE to remove a table.
--
-- O `if exists` só cobre "não existe", não "existe com outro tipo". Ambos os
-- comportamentos foram MEDIDOS, não presumidos: tools/diagnosticar_drop.mjs.
--
-- Por isso o tipo é consultado no catálogo e emite-se apenas o comando correto.
-- Cobre os três casos: não existe, é tabela (protótipo), é vista (execuções
-- seguintes). Foi a única construção que passou nas duas situações.
do $$
declare
  v_tipo "char";
begin
  select c.relkind into v_tipo
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'agenda';

  if v_tipo in ('v', 'm') then
    drop view if exists public.agenda cascade;
  elsif v_tipo in ('r', 'p') then
    drop table if exists public.agenda cascade;
  end if;
end $$;

create or replace view public.agenda as
  select a.id,
         a.utente_id,
         a.profissional_id,
         a.tipo::text            as tipo,
         (a.inicio at time zone 'Europe/Lisbon')::date as data,
         to_char(a.inicio at time zone 'Europe/Lisbon', 'HH24:MI') as hora,
         a.estado::text          as estado,
         a.clinica_id,
         a.especialidade,
         a.duracao_minutos,
         a.modalidade,
         a.created_at
    from public.agendamentos a;

comment on view public.agenda is
  'Compatibilidade com o protótipo (data/hora separadas). A fonte de verdade é agendamentos.';

-- ---------------------------------------------------------------------------
-- 2. Impedir duplo agendamento do mesmo profissional no mesmo intervalo.
--
-- PORQUE UM GATILHO E NÃO UMA CONSTRAINT DE EXCLUSÃO:
-- a solução elegante seria
--     exclude using gist (profissional_id with =,
--       tstzrange(inicio, inicio + make_interval(mins => duracao_minutos)) with &&)
-- mas o PostgreSQL não a aceita. Nem esta, nem nenhuma variante: uma
-- constraint de exclusão (e uma coluna GENERATED) só admite funções
-- IMMUTABLE, e o planeador recusa qualquer função dentro de um índice GiST
-- aqui — testado com make_interval nativo, com coluna GENERATED e com uma
-- função própria marcada immutable. A validação da migração apanhou isso.
--
-- Em vez de contornar a regra com um índice que não é aplicado, o que dá uma
-- falsa sensação de segurança, a sobreposição é verificada por gatilho. Vantagem
-- adicional que a constraint não tinha: a mensagem de erro pode dizer ao
-- utilizador EXATAMENTE com que marcação está a colidir, em português, em vez de
-- um "conflicting key value violates exclusion constraint".
--
-- Nota de integridade: um gatilho não é à prova de corrida entre duas
-- transações simultâneas. Para isso seria preciso uma constraint de exclusão
-- (impossível aqui) ou serializar as escritas da agenda. Em ambiente de uma
-- clínica o gatilho resolve o caso real; se um dia houver marcação online
-- concorrente em volume, esta decisão tem de ser revisitada com
-- pg_advisory_xact_lock por profissional.
-- ---------------------------------------------------------------------------
create extension if not exists btree_gist;

alter table public.agendamentos
  drop constraint if exists agendamentos_sem_sobreposicao;

create or replace function clinia.verificar_sobreposicao_agenda()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_inicio timestamptz := new.inicio;
  v_fim    timestamptz := new.inicio + clinia.minutos_intervalo(new.duracao_minutos::integer);
  v_conflito record;
begin
  -- Agendamentos que não ocupam tempo do profissional nunca colidem.
  if new.profissional_id is null
     or new.estado not in ('marcado','confirmado','em_sala','realizado') then
    return new;
  end if;

  select a.id,
         a.inicio,
         a.duracao_minutos,
         u.nome as utente
    into v_conflito
    from public.agendamentos a
    left join public.utentes u on u.id = a.utente_id
   where a.profissional_id = new.profissional_id
     and a.arquivado_em is null
     and (new.id is null or a.id <> new.id)
     and a.estado in ('marcado','confirmado','em_sala','realizado')
     and tstzrange(a.inicio, a.inicio + clinia.minutos_intervalo(a.duracao_minutos::integer))
         && tstzrange(v_inicio, v_fim)
   limit 1;

  if found then
    raise exception
      'O profissional já tem uma marcação sobreposta: % às % (duração % min).',
      coalesce(v_conflito.utente, 'utente não identificado'),
      to_char(v_conflito.inicio at time zone 'Europe/Lisbon', 'DD/MM/YYYY HH24:MI'),
      v_conflito.duracao_minutos
      using errcode = 'exclusion_violation',
            hint = 'Escolhe outro horário ou outra duração.';
  end if;

  return new;
end $$;

comment on function clinia.verificar_sobreposicao_agenda() is
  'Impede marcações sobrepostas do mesmo profissional, com mensagem que identifica o conflito.';

drop trigger if exists t_agendamentos_sobreposicao on public.agendamentos;
create trigger t_agendamentos_sobreposicao
  before insert or update of inicio, duracao_minutos, profissional_id, estado
  on public.agendamentos
  for each row execute function clinia.verificar_sobreposicao_agenda();

-- O gatilho é security definer (tem de ver a agenda toda para detetar o
-- conflito, independentemente das políticas de quem escreve).
grant execute on function clinia.verificar_sobreposicao_agenda() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Atos clínicos (motor genérico)
-- ---------------------------------------------------------------------------
create table if not exists public.atos_clinicos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  agendamento_id    uuid references public.agendamentos(id) on delete set null,
  profissional_id   uuid references public.profissionais(id) on delete set null,

  tipo              public.ato_tipo not null,
  especialidade     public.especialidade not null default 'mfr',
  -- Inicial vs follow-up: o formulário, os defaults e o que se pede mudam.
  fase              text not null default 'inicial',   -- inicial | seguimento | reavaliacao | alta
  estado            public.ato_estado not null default 'rascunho',

  data_hora         timestamptz not null default now(),
  duracao_minutos   smallint,
  modalidade        text not null default 'presencial',
  local             text,

  -- Cabeçalho clínico transversal a qualquer especialidade
  motivo            text,
  queixa            text,
  observacoes       text,
  -- Conteúdo específico do módulo. O núcleo não interpreta: guarda.
  dados             jsonb not null default '{}'::jsonb,

  -- Assinatura do ato: um ato assinado não se altera, retifica-se.
  assinado_por      uuid references public.perfis(id) on delete set null,
  assinado_em       timestamptz,
  assinatura_hash   text,             -- impressão digital do conteúdo assinado
  retifica_ato_id   uuid references public.atos_clinicos(id) on delete set null,
  retificado_motivo text,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,
  updated_by        uuid references public.perfis(id) on delete set null,

  constraint atos_fase_valida
    check (fase in ('inicial','seguimento','reavaliacao','alta')),
  constraint atos_modalidade_valida
    check (modalidade in ('presencial','teleconsulta','domicilio')),
  -- NOTA: aqui existia a constraint atos_assinatura_coerente, que exigia
  -- assinado_por e assinado_em preenchidos quando o estado não é rascunho.
  -- Foi REMOVIDA porque é impossível de satisfazer em conjunto com o gatilho
  -- clinia.assinar_ato(): as constraints CHECK são avaliadas ANTES dos
  -- gatilhos BEFORE, por isso a assinatura ainda estaria a null quando a CHECK
  -- corresse. A regra passou a ser imposta pelo próprio gatilho de assinatura
  -- (migração 0011), que é o único sítio onde pode ser verificada a tempo.
  constraint atos_retificacao_exige_motivo
    check (retifica_ato_id is null or length(btrim(coalesce(retificado_motivo,''))) > 0)
);

create index if not exists idx_atos_clinica_data on public.atos_clinicos (clinica_id, data_hora desc);
create index if not exists idx_atos_utente       on public.atos_clinicos (utente_id, data_hora desc);
create index if not exists idx_atos_episodio    on public.atos_clinicos (episodio_id, data_hora desc);
create index if not exists idx_atos_prof_data   on public.atos_clinicos (profissional_id, data_hora desc);
create index if not exists idx_atos_tipo        on public.atos_clinicos (clinica_id, tipo, especialidade);
create index if not exists idx_atos_agendamento on public.atos_clinicos (agendamento_id);
-- Índice GIN no JSONB do módulo: permite consultas pontuais sem tabela dedicada.
create index if not exists idx_atos_dados_gin   on public.atos_clinicos using gin (dados jsonb_path_ops);

drop trigger if exists t_atos_clinicos_updated_at on public.atos_clinicos;
create trigger t_atos_clinicos_updated_at
  before update on public.atos_clinicos
  for each row execute function clinia.set_updated_at();

comment on table public.atos_clinicos is
  'Motor de atos genérico. O conteúdo da especialidade vive em dados (jsonb) + tabelas tipadas do módulo.';

-- Fecha o laço agendamento <-> ato, agora que atos_clinicos existe.
alter table public.agendamentos
  drop constraint if exists agendamentos_ato_fk;
alter table public.agendamentos
  add constraint agendamentos_ato_fk
  foreign key (ato_id) references public.atos_clinicos(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 4. Motor de escalas — instrumentos versionados
--    Versionar não é preciosismo: se a Barthel mudar de redação, os scores
--    antigos têm de continuar a ser interpretáveis com a versão com que foram
--    medidos. Sem versão, o histórico perde validade.
-- ---------------------------------------------------------------------------
create table if not exists public.escalas (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid references public.clinicas(id) on delete cascade,  -- null = global
  codigo            text not null,
  nome              text not null,
  nome_curto        text,
  versao            text not null default '1.0',
  dominio           text not null default 'funcao',
    -- dor | funcao | movimento | forca | risco | qualidade_de_vida | performance | outro
  descricao         text,
  -- Método de pontuação, para a app calcular sozinha (baixa fricção: o clínico
  -- não soma à mão nem escreve números de cabeça)
  metodo            text not null default 'soma',
    -- soma | valor_unico | media | algoritmo
  score_min         numeric,
  score_max         numeric,
  -- Bandas de interpretação: [{max: 20, rotulo: "dependência total", gravidade: "grave"}]
  interpretacao     jsonb not null default '[]'::jsonb,
  -- Escalas que se apoiam em observação direta (EVA, testes ortopédicos) em vez
  -- de perguntas com resposta fechada
  baseada_observacao boolean not null default false,
  itens             jsonb not null default '[]'::jsonb,  -- atalho de leitura; fonte é escala_itens
  -- Aplicável a que populações
  populacao         text[] not null default '{}',  -- adulto | pediatrico | senior
  especialidade     public.especialidade not null default 'mfr',
  referencia_bibliografica text,
  licenca           text,                       -- algumas escalas têm restrições de uso
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint escalas_metodo_valido
    check (metodo in ('soma','valor_unico','media','algoritmo')),
  constraint escalas_score_coerente
    check (score_min is null or score_max is null or score_min <= score_max)
);

create unique index if not exists uq_escalas_codigo_versao_global
  on public.escalas (codigo, versao) where clinica_id is null;
create unique index if not exists uq_escalas_codigo_versao_clinica
  on public.escalas (clinica_id, codigo, versao) where clinica_id is not null;

drop trigger if exists t_escalas_updated_at on public.escalas;
create trigger t_escalas_updated_at
  before update on public.escalas
  for each row execute function clinia.set_updated_at();

create table if not exists public.escala_itens (
  id             uuid primary key default gen_random_uuid(),
  escala_id      uuid not null references public.escalas(id) on delete cascade,
  ordem          smallint not null,
  codigo         text not null,
  texto          text not null,
  ajuda          text,                          -- texto de apoio ao clínico
  tipo_resposta  text not null default 'opcoes',
    -- opcoes | numero | booleano | texto | observacao | escala_visual
  -- [{valor: 0, rotulo: "não consegue"}, {valor: 5, rotulo: "sem ajuda"}]
  opcoes         jsonb not null default '[]'::jsonb,
  min_valor      numeric,
  max_valor      numeric,
  unidade        text,
  peso           numeric not null default 1,
  -- Itens que invertem a pontuação (ex.: escalas de dor/fadiga)
  invertido      boolean not null default false,
  obrigatorio    boolean not null default true,
  permite_lado   boolean not null default false,   -- itens de movimento medidos à D e à E
  -- Dimensão do vetor a que o item pertence: dor | movimento | funcao
  vetor          text,
  created_at     timestamptz not null default now(),
  constraint escala_itens_tipo_valido
    check (tipo_resposta in ('opcoes','numero','booleano','texto','observacao','escala_visual')),
  constraint escala_itens_vetor_valido
    check (vetor is null or vetor in ('dor','movimento','funcao')),
  constraint escala_itens_ordem_unica unique (escala_id, ordem),
  constraint escala_itens_codigo_unico unique (escala_id, codigo)
);

create index if not exists idx_escala_itens_escala on public.escala_itens (escala_id, ordem);

comment on table public.escalas is
  'Instrumentos de avaliação versionados. Global ou por clínica.';

-- ---------------------------------------------------------------------------
-- 5. Utilitário: calcular o score de uma escala a partir das respostas
--    Baixa fricção na prática: o clínico responde, o sistema soma.
-- ---------------------------------------------------------------------------
create or replace function clinia.calcular_score_escala(p_escala uuid, p_respostas jsonb)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_metodo text;
  v_total  numeric := 0;
  v_conta  integer := 0;
  v_item   record;
  v_valor  numeric;
begin
  select metodo into v_metodo from public.escalas where id = p_escala;
  if v_metodo is null then
    return null;
  end if;

  if v_metodo = 'valor_unico' then
    -- Escalas de resposta única (ex.: EVA): a resposta é o score.
    return nullif(p_respostas ->> 'valor', '')::numeric;
  end if;

  for v_item in
    select codigo, peso, invertido, min_valor, max_valor, tipo_resposta
      from public.escala_itens
     where escala_id = p_escala
     order by ordem
  loop
    v_valor := nullif(p_respostas -> v_item.codigo ->> 'valor', '')::numeric;
    continue when v_valor is null;

    if v_item.invertido and v_item.min_valor is not null and v_item.max_valor is not null then
      v_valor := v_item.min_valor + v_item.max_valor - v_valor;
    end if;

    v_total := v_total + (v_valor * coalesce(v_item.peso, 1));
    v_conta := v_conta + 1;
  end loop;

  if v_conta = 0 then
    return null;
  end if;

  if v_metodo = 'media' then
    return round(v_total / v_conta, 2);
  end if;

  -- 'soma' e 'algoritmo' (o algoritmo específico é refinado no módulo)
  return v_total;
end $$;

comment on function clinia.calcular_score_escala(uuid, jsonb) is
  'Calcula o score a partir das respostas. O clínico não soma à mão (baixa fricção).';


-- ----------------------------------------------------------------------------
-- 0007_modulo_mfr.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0007 — MÓDULO MFR
--
-- Este ficheiro é o módulo. O núcleo (0006) não sabe o que é uma EVA nem uma
-- ADM de ombro; sabe o que é um ato clínico. Tudo o que é MFR vive aqui e
-- pendura-se num ato por ato_id.
--
-- Decisão de arquitetura: o módulo MFR NÃO é apenas jsonb. Motivo — o que
-- precisa de ser agregado, comparado e desenhado em gráfico (EVA, ADM, escalas,
-- força) tem de ser tipado, senão o gráfico de evolução é impossível de fazer
-- com rigor. O jsonb fica para o que é narrativo e esparso (mapa de dor,
-- testes ortopédicos assinalados). Promovemos a tabela só o que se consulta.
--
-- Fonte clínica: entradas #001 e #003 da base de conhecimento (Pedro Cunha).
--   · Três vetores: Dor · Movimento · Função
--   · "Nem sempre há dor; pode ser sinal ou proteção" → sem_dor é um valor válido
--   · "A avaliação faz-se sempre pelo movimento" → movimento é medida, em graus
--   · "Estás em alta quando voltas a fazer o que fazias" → critério de alta
--     ligado à atividade do utente, não a um número de sessões
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. DOR — caracterizada pela ORIGEM, não só pela intensidade (EVA)
--    A EVA sozinha é a maior fonte de má decisão clínica: 7/10 nociceptivo e
--    7/10 nociplástico pedem tratamentos opostos.
-- ---------------------------------------------------------------------------
create table if not exists public.mfr_avaliacao_dor (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  -- Intensidade: as três leituras que importam e que o doente distingue bem
  eva_atual         smallint,      -- neste momento
  eva_habitual      smallint,      -- em média nos últimos dias
  eva_melhor        smallint,      -- o melhor das últimas 24h
  eva_pior          smallint,      -- o pior das últimas 24h

  -- O núcleo clínico: que tipo de dor é esta
  origem            public.dor_origem not null default 'sem_dor',
  padrao_temporal   public.dor_padrao_temporal,
  inicio            date,
  duracao_texto     text,          -- "3 semanas", "desde 2019"
  -- Dor que acorda / dor em repouso são bandeiras vermelhas e de rastreio
  acorda_a_noite    boolean,
  em_repouso        boolean,
  alivia_com        text[] not null default '{}',
  agrava_com        text[] not null default '{}',

  -- Localização: lista estruturada + desenho no corpo (coordenadas normalizadas)
  localizacao       text[] not null default '{}',
  lateralidade      text,
  irradiacao        text,
  mapa_corporal     jsonb not null default '[]'::jsonb,
    -- [{x:0.42,y:0.31,zona:" lombar",intensidade:7,tipo:"queimadura"}]

  -- Qualidade e sintomas associados — orientam o raciocínio mecanístico
  qualidade         text[] not null default '{}',
    -- queimadura, choque, formigueiro, peso, aperto, latejante, rigidez...
  sintomas_associados text[] not null default '{}',
  sintomas_neurologicos jsonb not null default '{}'::jsonb,
    -- {parestesias:true, perda_forca:false, alteracao_sensibilidade:true, ...}

  -- Modelo biopsicossocial: o que amplifica e o que protege
  fatores_psicossociais jsonb not null default '{}'::jsonb,
    -- {medo_movimento:true, catastrofizacao:"alta", sono:"mau", stress:true, ...}
  bandeiras_vermelhas text[] not null default '{}',
    -- rastreio de patologia grave: obrigatório no registo de dor
  bandeiras_amarelas text[] not null default '{}',
    -- prognóstico: crenças, compensação, contexto laboral

  descricao_livre   text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint mfr_dor_eva_intervalo
    check (eva_atual between 0 and 10
       and (eva_habitual between 0 and 10 or eva_habitual is null)
       and (eva_melhor   between 0 and 10 or eva_melhor is null)
       and (eva_pior     between 0 and 10 or eva_pior is null)),
  constraint mfr_dor_ordem_evas
    check (eva_melhor is null or eva_pior is null or eva_melhor <= eva_pior),
  -- Coerência que evita registos contraditórios: origem 'sem_dor' com EVA > 0
  -- é erro de preenchimento, e este erro contamina todos os relatórios.
  constraint mfr_dor_sem_dor_coerente
    check (origem <> 'sem_dor' or eva_atual is null or eva_atual = 0),
  constraint mfr_dor_uma_por_ato unique (ato_id)
);

create index if not exists idx_mfr_dor_ato      on public.mfr_avaliacao_dor (ato_id);
create index if not exists idx_mfr_dor_episodio on public.mfr_avaliacao_dor (episodio_id, created_at desc);
create index if not exists idx_mfr_dor_origem   on public.mfr_avaliacao_dor (clinica_id, origem);

drop trigger if exists t_mfr_dor_updated_at on public.mfr_avaliacao_dor;
create trigger t_mfr_dor_updated_at
  before update on public.mfr_avaliacao_dor
  for each row execute function clinia.set_updated_at();

comment on table public.mfr_avaliacao_dor is
  'Vetor DOR. Caracterização por origem (biopsicossocial), não só por EVA.';

-- ---------------------------------------------------------------------------
-- 2. MOVIMENTO — "a avaliação faz-se sempre pelo movimento"
--    Uma linha por movimento observado. É esta granularidade que permite
--    desenhar a evolução da ADM de um ombro ao longo de 20 sessões.
-- ---------------------------------------------------------------------------
create table if not exists public.mfr_movimento (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  regiao            text,                       -- rótulo legível: "ombro direito"
  articulacao_codigo text references public.articulacoes(codigo) on delete set null,
  movimento         text not null,              -- flexao, abducao, rotacao_interna...
  lado              text,                       -- d | e | bilateral | central

  -- Medições
  adm_ativa        numeric,                     -- graus, o que o doente faz sozinho
  adm_passiva      numeric,                     -- graus, o que o examinador consegue
  adm_normal       numeric,                     -- referência usada na avaliação
  forca            smallint,                    -- escala de Oxford 0-5
  dor_ao_movimento smallint,                    -- EVA durante o movimento (0-10)
  fim_de_amplitude text,                        -- "dor", "rigidez", "normal", "espasmo"
  qualidade_movimento text,                     -- fluidez, compensação, dissociação

  -- Testes: nome + resultado. Especificidade de cada teste é do clínico, não nossa.
  testes           jsonb not null default '[]'::jsonb,
    -- [{nome:"Neer", resultado:"positivo", dor:true}, {nome:"Jobe", resultado:"negativo"}]
  -- Observação qualitativa: o que o clínico viu e que nenhum número capta
  observacao       text,
  -- Marcar como limitação principal poupa tempo na construção do plano
  limitacao_principal boolean not null default false,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint mfr_movimento_lado_valido
    check (lado is null or lado in ('d','e','bilateral','central')),
  constraint mfr_movimento_forca_oxford check (forca between 0 and 5 or forca is null),
  constraint mfr_movimento_eva check (dor_ao_movimento between 0 and 10 or dor_ao_movimento is null),
  constraint mfr_movimento_adm_sanidade
    check (adm_ativa is null or adm_ativa between 0 and 360),
  constraint mfr_movimento_fim_amplitude_valido
    check (fim_de_amplitude is null or fim_de_amplitude in
      ('normal','dor','rigidez','espasmo','apreensao','forca_muscular','outro'))
);

create index if not exists idx_mfr_mov_ato         on public.mfr_movimento (ato_id);
create index if not exists idx_mfr_mov_episodio    on public.mfr_movimento (episodio_id, created_at desc);
create index if not exists idx_mfr_mov_articulacao on public.mfr_movimento (articulacao_codigo, movimento);
create index if not exists idx_mfr_mov_utente      on public.mfr_movimento (utente_id, movimento, lado);

comment on table public.mfr_movimento is
  'Vetor MOVIMENTO. Medições estruturadas por articulação e movimento (ADM, força, dor).';

-- ---------------------------------------------------------------------------
-- 3. FUNÇÃO — as atividades que o utente QUER voltar a fazer
--    Esta tabela alimenta diretamente o plano e o critério de alta.
-- ---------------------------------------------------------------------------
create table if not exists public.mfr_avaliacao_funcao (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  -- O que a pessoa deixou de conseguir fazer. Nas palavras dela.
  atividades_limitadas jsonb not null default '[]'::jsonb,
    -- [{atividade:"vestir o casaco", dificuldade:3, importante:true},
    --  {atividade:"jogar futebol com o filho", dificuldade:5, importante:true}]
  -- O que a pessoa QUER voltar a fazer — é o objetivo, não a limitação
  atividades_pretendidas jsonb not null default '[]'::jsonb,
    -- [{atividade:"voltar a conduzir 1h", prazo:"3 meses", prioridade:1}]
  -- Impacto na vida: trabalho, casa, desporto, sono, relações
  impacto_trabalho   text,
  impacto_domestico  text,
  impacto_desporto   text,
  impacto_social     text,
  impacto_emocional  text,

  -- Escalas funcionais aplicadas neste ato ficam em mfr_escala_aplicada
  -- (Barthel, Índice de Katz, DASH, Oswestry...). Aqui fica o resumo clínico.
  resumo_funcional   text,
  participacao       text,     -- como a limitação condiciona a participação social
  ambiente           text,     -- barreiras e facilitadores (escadas, carro, posto de trabalho)

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint mfr_funcao_uma_por_ato unique (ato_id)
);

create index if not exists idx_mfr_funcao_ato      on public.mfr_avaliacao_funcao (ato_id);
create index if not exists idx_mfr_funcao_episodio on public.mfr_avaliacao_funcao (episodio_id);

drop trigger if exists t_mfr_funcao_updated_at on public.mfr_avaliacao_funcao;
create trigger t_mfr_funcao_updated_at
  before update on public.mfr_avaliacao_funcao
  for each row execute function clinia.set_updated_at();

comment on table public.mfr_avaliacao_funcao is
  'Vetor FUNÇÃO. Define objetivos e critério de alta — não o número de sessões.';

-- ---------------------------------------------------------------------------
-- 4. MEDIÇÕES — a série temporal que faz o gráfico de evolução
--    Separada do movimento porque uma medição pode vir de um teste de
--    performance, de uma escala ou de um instrumento, e todas têm de cair no
--    mesmo gráfico. "Antes" e "depois" da sessão no mesmo registo: é assim que
--    se mede o efeito imediato de uma técnica.
-- ---------------------------------------------------------------------------
create table if not exists public.medicoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  ato_id            uuid references public.atos_clinicos(id) on delete cascade,
  tipo_medicao_id   uuid references public.tipos_medicao(id) on delete set null,

  codigo            text not null,            -- desnormalizado: sobrevive à remoção do tipo
  rotulo            text,                     -- rótulo legível no momento da medição
  categoria         text not null default 'movimento',
  valor             numeric not null,
  unidade           text,
  lado              text,
  momento           text not null default 'avaliacao',
    -- avaliacao | antes | depois | alta | seguimento
  movimento         text,
  articulacao_codigo text,
  contexto          text,                     -- "em carga", "sentado", "5º minuto"
  melhor_direcao    text not null default 'maior_melhor',
  notas             text,

  medido_por        uuid references public.profissionais(id) on delete set null,
  medido_em         timestamptz not null default now(),
  created_at        timestamptz not null default now(),

  constraint medicoes_momento_valido
    check (momento in ('avaliacao','antes','depois','alta','seguimento')),
  constraint medicoes_direcao_valida
    check (melhor_direcao in ('maior_melhor','menor_melhor','neutro')),
  constraint medicoes_lado_valido
    check (lado is null or lado in ('d','e','bilateral','central'))
);

create index if not exists idx_medicoes_evolucao on public.medicoes (utente_id, codigo, medido_em);
create index if not exists idx_medicoes_episodio on public.medicoes (episodio_id, codigo, medido_em);
create index if not exists idx_medicoes_ato      on public.medicoes (ato_id);

comment on table public.medicoes is
  'Série temporal de medições. Fonte única do gráfico de evolução (entrada #003).';

-- ---------------------------------------------------------------------------
-- 5. ESCALAS APLICADAS (no módulo MFR)
--    O score é calculado por clinia.calcular_score_escala e gravado: o histórico
--    não pode mudar se a escala for reeditada depois.
-- ---------------------------------------------------------------------------
create table if not exists public.mfr_escala_aplicada (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  escala_id         uuid not null references public.escalas(id) on delete restrict,
  escala_codigo     text not null,            -- desnormalizado, congela o que foi aplicado
  escala_versao     text not null,
  vetor             text,                     -- dor | movimento | funcao
  respostas         jsonb not null default '{}'::jsonb,
  score             numeric,
  score_calculado   boolean not null default false,   -- false = introduzido à mão
  interpretacao     text,                     -- "dependência moderada"
  gravidade         text,                     -- leve | moderada | grave | total
  notas             text,

  aplicada_por      uuid references public.profissionais(id) on delete set null,
  aplicada_em       timestamptz not null default now(),
  created_at        timestamptz not null default now(),

  constraint mfr_escala_vetor_valido
    check (vetor is null or vetor in ('dor','movimento','funcao'))
);

create index if not exists idx_mfr_escala_ato      on public.mfr_escala_aplicada (ato_id);
create index if not exists idx_mfr_escala_evolucao on public.mfr_escala_aplicada (utente_id, escala_codigo, aplicada_em desc);
create index if not exists idx_mfr_escala_episodio on public.mfr_escala_aplicada (episodio_id, escala_codigo);

comment on table public.mfr_escala_aplicada is
  'Escala aplicada com score congelado. Código e versão desnormalizados de propósito.';

-- ---------------------------------------------------------------------------
-- 6. SINTOMAS / observações estruturadas por região (campo narrativo apoiado)
-- ---------------------------------------------------------------------------
create table if not exists public.mfr_observacoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  categoria         text not null default 'geral',
    -- inspecao | palpacao | neurologico | testes_especiais | marcha | postura | geral
  regiao            text,
  achado            text not null,
  relevancia        text not null default 'informativo',   -- informativo | relevante | critico
  created_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null
);

create index if not exists idx_mfr_obs_ato on public.mfr_observacoes (ato_id, categoria);

-- ---------------------------------------------------------------------------
-- 7. SESSÃO — o registo do que se fez e do que resultou
--    SOAP continua em aberto na base de conhecimento (pergunta #2 ao Pedro):
--    o schema suporta-o sem o impor. Os quatro campos são opcionais.
--
--    A limpeza é necessária pela mesma razão das migrações 0002 e 0003: o
--    protótipo tinha uma tabela `sessoes` com outra estrutura (sem `ato_id` nem
--    `episodio_id`), e `create table if not exists` deixá-la-ia como estava.
-- ---------------------------------------------------------------------------
drop table if exists public.sessoes cascade;

create table if not exists public.sessoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  profissional_id   uuid references public.profissionais(id) on delete set null,

  numero_sessao     integer,                  -- 1..N dentro do episódio
  data_sessao       date not null default current_date,
  hora_inicio       time,
  hora_fim          time,
  duracao_minutos   smallint default 45,

  -- SOAP
  subjetivo         text,                     -- o que o doente relata
  objetivo          text,                     -- o que se observou/mediu
  avaliacao         text,                     -- interpretação clínica
  plano             text,                     -- o que se fará a seguir

  -- Resposta à sessão anterior: a pergunta mais informativa do follow-up
  resposta          public.sessao_resposta,
  eva_antes         smallint,
  eva_depois        smallint,
  -- Reação adversa: tem de ser registável e visível (segurança clínica)
  evento_adverso    text,

  -- Técnicas aplicadas neste dia, com parâmetros. Permite saber o que funcionou.
  tecnicas          jsonb not null default '[]'::jsonb,
    -- [{tecnica:"mobilização neural", regiao:"ciático D", dose:"3x30s", resposta:"melhoria"}]
  exercicios_realizados jsonb not null default '[]'::jsonb,
  -- Progressão de carga: sem isto não se sabe se o plano está a progredir
  carga             jsonb not null default '{}'::jsonb,
  -- Adesão ao plano de casa, autorrelatada. Determina se o problema é a
  -- prescrição ou a execução.
  adesao_hep        smallint,                 -- 0-10
  observacoes       text,

  -- Uma sessão registada é histórico clínico: NÃO se apaga. O gatilho de
  -- soft-delete da migração 0011 converte qualquer DELETE em arquivo, e para
  -- isso a coluna tem de existir. Registar isto aqui é uma decisão de produto,
  -- não uma questão técnica: apagar uma sessão apagaria a prova de que o
  -- tratamento foi feito.
  arquivado_em      timestamptz,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint sessoes_eva_intervalo
    check ((eva_antes between 0 and 10 or eva_antes is null)
       and (eva_depois between 0 and 10 or eva_depois is null)),
  constraint sessoes_adesao_intervalo
    check (adesao_hep between 0 and 10 or adesao_hep is null),
  constraint sessoes_resposta_valida
    check (resposta is null or resposta in ('melhor','igual','pior','flutuante')),
  constraint sessoes_horas_coerentes
    check (hora_fim is null or hora_inicio is null or hora_fim >= hora_inicio),
  constraint sessoes_uma_por_ato unique (ato_id)
);

create index if not exists idx_sessoes_episodio on public.sessoes (episodio_id, data_sessao desc);
create index if not exists idx_sessoes_utente   on public.sessoes (utente_id, data_sessao desc);
create index if not exists idx_sessoes_prof     on public.sessoes (profissional_id, data_sessao desc);

drop trigger if exists t_sessoes_updated_at on public.sessoes;
create trigger t_sessoes_updated_at
  before update on public.sessoes
  for each row execute function clinia.set_updated_at();

comment on table public.sessoes is
  'Sessão de tratamento (SOAP opcional). Substitui a tabela sessoes do protótipo.';

-- Liga a estrutura invertida da sessão de volta ao ato, para navegação rápida.
drop trigger if exists t_mfr_ligar_sessao on public.sessoes;

create or replace function clinia.ligar_sessao_ao_mfr()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
begin
  update public.atos_clinicos a
     set dados = coalesce(a.dados, '{}'::jsonb) || jsonb_build_object('sessao_id', new.id)
   where a.id = new.ato_id;
  return new;
end $$;

create trigger t_mfr_ligar_sessao
  after insert on public.sessoes
  for each row execute function clinia.ligar_sessao_ao_mfr();


-- ----------------------------------------------------------------------------
-- 0008_plano_objetivos_alta.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0008 — Plano, objetivos e critério de alta
--
-- Esta migração existe por causa de uma frase do Pedro (entrada #003):
--   "Estás em alta quando voltas a fazer o que fazias ou algo que desejas
--    fazer — voltar a trabalhar, ao desporto, um movimento específico,
--    arrumar os copos em casa."
--
-- Consequência de desenho: o plano NÃO se conta em sessões. Conta-se em
-- objetivos funcionais escolhidos pelo utente, cada um com um critério de alta
-- explícito e observável. E o sistema tem de conseguir dizer se o critério foi
-- cumprido — senão a alta volta a ser uma decisão arbitrária.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Plano de tratamento (um por episódio)
-- ---------------------------------------------------------------------------
create table if not exists public.planos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  episodio_id       uuid not null references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,

  versao            smallint not null default 1,
  estado            text not null default 'ativo',   -- rascunho | ativo | concluido | substituido
  data_inicio       date not null default current_date,
  data_revisao_prevista date,
  data_fim          date,

  -- Quadro geral em três vetores: como se ataca a dor, o movimento e a função
  abordagem_dor     text,
  abordagem_movimento text,
  abordagem_funcao  text,
  -- Técnicas e modalidades previstas, com dose
  tecnicas_previstas jsonb not null default '[]'::jsonb,
  -- Educação e autogestão: em dor crónica é frequentemente o que mais muda o prognóstico
  educacao          text,
  -- Estimativa de número de sessões — é uma ESTIMATIVA, nunca o critério de alta
  sessoes_previstas smallint,
  frequencia_semanal smallint,
  -- Progressão de carga planeada (o que sobe, quando e quanto)
  progressao_carga  jsonb not null default '{}'::jsonb,
  -- Riscos, precauções e o que NÃO fazer. Campo de segurança.
  precaucoes        text,
  indicadores_progresso text,
  notas             text,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,
  updated_by        uuid references public.perfis(id) on delete set null,

  constraint planos_estado_valido
    check (estado in ('rascunho','ativo','concluido','substituido')),
  constraint planos_versao_positiva check (versao >= 1),
  constraint planos_datas_coerentes
    check (data_fim is null or data_fim >= data_inicio)
);

create index if not exists idx_planos_episodio on public.planos (episodio_id, versao desc);
create index if not exists idx_planos_ativo
  on public.planos (episodio_id) where estado = 'ativo' and arquivado_em is null;

drop trigger if exists t_planos_updated_at on public.planos;
create trigger t_planos_updated_at
  before update on public.planos
  for each row execute function clinia.set_updated_at();

comment on column public.planos.sessoes_previstas is
  'ESTIMATIVA de organização da agenda. NUNCA é critério de alta (entrada #003).';

-- ---------------------------------------------------------------------------
-- 2. Objetivos do plano — o coração da decisão de alta
-- ---------------------------------------------------------------------------
create table if not exists public.plano_objetivos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  plano_id          uuid not null references public.planos(id) on delete cascade,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  ordem             smallint not null default 1,
  tipo              public.objetivo_tipo not null default 'atividade_utente',
  -- A atividade na linguagem do utente: "arrumar os copos no armário de cima"
  descricao         text not null,
  -- Domínio CIF / atividade, quando aplicável
  cif_codigo        text references public.cif_catalogo(codigo) on delete set null,
  -- Ligação explícita ao movimento/medição que serve este objetivo
  medicao_codigo    text,
  lado              text,

  -- CRITÉRIO DE ALTA: tem de ser observável e verificável.
  criterio_atingimento text not null,
  -- Valores alvo, quando o objetivo é quantificável
  valor_baseline    numeric,
  valor_alvo        numeric,
  unidade           text,
  melhor_direcao    text not null default 'maior_melhor',
  -- Prazo: dá expectativa ao utente e permite detetar estagnação
  prazo             date,

  estado            public.objetivo_estado not null default 'em_curso',
  progresso_percentual smallint not null default 0,
  data_atingimento  date,
  -- Evidência de que foi atingido (o que se observou, não o que se assumiu)
  evidencia         text,

  -- Quem escolheu: objetivo imposto pelo clínico não é objetivo do utente, e
  -- a adesão depende disto (entrada #003).
  definido_pelo_utente boolean not null default true,
  prioridade        smallint not null default 2,      -- 1 alta, 2 média, 3 baixa
  notas             text,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint plano_objetivos_descricao_nao_vazia check (length(btrim(descricao)) > 0),
  constraint plano_objetivos_criterio_nao_vazio
    check (length(btrim(criterio_atingimento)) > 0),
  constraint plano_objetivos_estado_valido
    check (estado in ('em_curso','atingido','parcialmente_atingido','nao_atingido','abandonado')),
  constraint plano_objetivos_progresso_intervalo
    check (progresso_percentual between 0 and 100),
  constraint plano_objetivos_direcao_valida
    check (melhor_direcao in ('maior_melhor','menor_melhor','neutro')),
  constraint plano_objetivos_prioridade_valida check (prioridade between 1 and 3),
  -- Coerência: objetivo marcado como atingido tem de ter data de atingimento.
  constraint plano_objetivos_atingido_tem_data
    check (estado <> 'atingido' or data_atingimento is not null),
  constraint plano_objetivos_ordem_unica unique (plano_id, ordem)
);

create index if not exists idx_plano_objetivos_plano    on public.plano_objetivos (plano_id, ordem);
create index if not exists idx_plano_objetivos_episodio on public.plano_objetivos (episodio_id, estado);
create index if not exists idx_plano_objetivos_ativos
  on public.plano_objetivos (episodio_id) where estado = 'em_curso' and arquivado_em is null;

drop trigger if exists t_plano_objetivos_updated_at on public.plano_objetivos;
create trigger t_plano_objetivos_updated_at
  before update on public.plano_objetivos
  for each row execute function clinia.set_updated_at();

comment on table public.plano_objetivos is
  'Objetivos funcionais do utente com critério de alta observável (entrada #003).';

-- ---------------------------------------------------------------------------
-- 3. Critérios de alta do episódio
--    A alta é uma decisão clínica com fundamento, não o fim de um pacote de
--    sessões. Guardamos o critério, quem o cumpriu e como.
-- ---------------------------------------------------------------------------
create table if not exists public.criterios_alta (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  episodio_id       uuid not null references public.episodios(id) on delete cascade,
  objetivo_id       uuid references public.plano_objetivos(id) on delete set null,

  descricao         text not null,
  tipo              text not null default 'funcional',
    -- funcional | medida | escala | adesao | decisao_clinica | administrativo
  medicao_codigo    text,
  escala_id         uuid references public.escalas(id) on delete set null,
  valor_alvo        numeric,
  operador          text not null default '>=',       -- >= | <= | =
  cumprido          boolean not null default false,
  cumprido_em       date,
  verificado_por    uuid references public.profissionais(id) on delete set null,
  evidencia         text,
  ordem             smallint not null default 1,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint criterios_alta_operador_valido
    check (operador in ('>=','<=','=')),
  constraint criterios_alta_tipo_valido
    check (tipo in ('funcional','medida','escala','adesao','decisao_clinica','administrativo')),
  constraint criterios_alta_descricao_nao_vazia check (length(btrim(descricao)) > 0),
  constraint criterios_alta_cumprido_tem_data
    check (not cumprido or cumprido_em is not null)
);

create index if not exists idx_criterios_alta_episodio on public.criterios_alta (episodio_id, ordem);

drop trigger if exists t_criterios_alta_updated_at on public.criterios_alta;
create trigger t_criterios_alta_updated_at
  before update on public.criterios_alta
  for each row execute function clinia.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Progresso dos objetivos (histórico)
--    Um objetivo não muda de 0% para 100%: há uma trajetória e ela é a prova
--    de que o tratamento está a funcionar (ou não).
-- ---------------------------------------------------------------------------
create table if not exists public.objetivo_progresso (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  objetivo_id       uuid not null references public.plano_objetivos(id) on delete cascade,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,
  data_registo      date not null default current_date,
  progresso_percentual smallint not null,
  estado            public.objetivo_estado,
  observacao        text,
  registado_por     uuid references public.profissionais(id) on delete set null,
  created_at        timestamptz not null default now(),
  constraint objetivo_progresso_intervalo check (progresso_percentual between 0 and 100)
);

create index if not exists idx_objetivo_progresso on public.objetivo_progresso (objetivo_id, data_registo desc);

-- ---------------------------------------------------------------------------
-- 5. Exercícios e HEP (Home Exercise Programme)
--    Prescrever exercício é metade do tratamento em MFR. A biblioteca é
--    global ou da clínica; a prescrição é sempre do utente.
-- ---------------------------------------------------------------------------
create table if not exists public.exercicios (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid references public.clinicas(id) on delete cascade,  -- null = global
  codigo            text,
  nome              text not null,
  descricao         text,
  instrucoes        text,
  -- Como se faz bem: erros comuns são a causa nº1 de exercício ineficaz
  erros_comuns      text,
  regiao            text,
  articulacao_codigo text references public.articulacoes(codigo) on delete set null,
  objetivo          text,     -- mobilidade | fortalecimento | controlo_motor | alongamento | respiratorio | equilibrio
  dificuldade       smallint, -- 1-5, para progressão
  -- Parâmetros por omissão: séries, repetições, frequência. Poupa cliques.
  series_default    smallint,
  reps_default      text,
  tempo_default     text,
  frequencia_default text,
  -- Como progredir e como regredir: sem isto o utente estagna ou lesiona-se
  progressao        text,
  regressao         text,
  equipamento       text[] not null default '{}',
  contraindicacoes  text,
  video_url         text,     -- Storage UE, não CDN externo
  imagem_url        text,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint exercicios_dificuldade_intervalo
    check (dificuldade between 1 and 5 or dificuldade is null)
);

create unique index if not exists uq_exercicios_codigo_global
  on public.exercicios (codigo) where clinica_id is null and codigo is not null;
create index if not exists idx_exercicios_regiao on public.exercicios (regiao, objetivo);

drop trigger if exists t_exercicios_updated_at on public.exercicios;
create trigger t_exercicios_updated_at
  before update on public.exercicios
  for each row execute function clinia.set_updated_at();

create table if not exists public.hep_prescricoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  plano_id          uuid references public.planos(id) on delete set null,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,

  titulo            text,
  data_inicio       date not null default current_date,
  data_fim          date,
  -- Frequência global do programa de casa
  frequencia_global text,
  orientacoes       text,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null
);

create index if not exists idx_hep_utente on public.hep_prescricoes (utente_id, data_inicio desc);
create index if not exists idx_hep_episodio on public.hep_prescricoes (episodio_id);
create index if not exists idx_hep_ativo on public.hep_prescricoes (utente_id) where ativo;

drop trigger if exists t_hep_prescricoes_updated_at on public.hep_prescricoes;
create trigger t_hep_prescricoes_updated_at
  before update on public.hep_prescricoes
  for each row execute function clinia.set_updated_at();

create table if not exists public.hep_exercicios (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  -- utente_id é desnormalizado de propósito: o portal do utente tem de poder
  -- listar os seus exercícios sem uma junção a hep_prescricoes, e as políticas
  -- RLS de portal filtram por utente_id. Sem esta coluna, a tabela filha não
  -- teria como saber a quem pertence.
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  prescricao_id     uuid not null references public.hep_prescricoes(id) on delete cascade,
  exercicio_id      uuid references public.exercicios(id) on delete set null,
  ordem             smallint not null default 1,
  -- Cópia dos parâmetros no momento da prescrição: a biblioteca pode mudar,
  -- a prescrição do doente não.
  nome              text not null,
  instrucoes        text,
  series            text,
  reps              text,
  tempo             text,
  frequencia        text,
  carga             text,
  notas             text,
  -- Adesão autorrelatada, para perceber se o problema é a prescrição ou a execução
  adesao_percebida  smallint,
  dificuldade_percebida smallint,
  created_at        timestamptz not null default now(),
  constraint hep_exercicios_adesao_intervalo
    check (adesao_percebida between 0 and 10 or adesao_percebida is null),
  constraint hep_exercicios_ordem_unica unique (prescricao_id, ordem)
);

create index if not exists idx_hep_exercicios_prescricao on public.hep_exercicios (prescricao_id, ordem);

-- ---------------------------------------------------------------------------
-- 6. Ligação inversa ato -> sessão (substitui o gatilho da migração 0007)
--    A coluna é a forma limpa de o ato saber que sessão gerou: sem UPDATE
--    escondido em cada gravação de sessão.
-- ---------------------------------------------------------------------------
alter table public.atos_clinicos
  add column if not exists sessao_id uuid;

alter table public.atos_clinicos
  drop constraint if exists atos_clinicos_sessao_fk;
alter table public.atos_clinicos
  add constraint atos_clinicos_sessao_fk
  foreign key (sessao_id) references public.sessoes(id) on delete set null;

drop trigger if exists t_mfr_ligar_sessao on public.sessoes;
drop function if exists clinia.ligar_sessao_ao_mfr();

comment on column public.atos_clinicos.sessao_id is
  'Sessão gerada por este ato. Preenchido pelo cliente no mesmo fluxo de gravação.';

-- ---------------------------------------------------------------------------
-- 7. Vista de suporte à decisão de alta
--    Responde à pergunta que o clínico faz antes de dar alta: "cumpro os
--    critérios que definimos?" — e é a vista que a app usa no ecrã da alta.
-- ---------------------------------------------------------------------------
create or replace view public.vw_episodio_objetivos as
  select o.clinica_id,
         o.episodio_id,
         o.utente_id,
         count(*)                                                      as total_objetivos,
         count(*) filter (where o.estado = 'atingido')                 as atingidos,
         count(*) filter (where o.estado = 'em_curso')                 as em_curso,
         count(*) filter (where o.estado = 'nao_atingido')             as nao_atingidos,
         round(avg(o.progresso_percentual), 1)                         as progresso_medio,
         min(o.prazo)                                                  as prazo_mais_proximo,
         bool_and(o.estado = 'atingido')                               as todos_atingidos
    from public.plano_objetivos o
   where o.arquivado_em is null
   group by o.clinica_id, o.episodio_id, o.utente_id;

comment on view public.vw_episodio_objetivos is
  'Suporte à decisão de alta: quantos objetivos do utente estão cumpridos.';


-- ----------------------------------------------------------------------------
-- 0009_requisicoes_receituario_documentos.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0009 — Requisições, receituário, relatórios e media
--
-- O blueprint identificou isto como lacuna do protótipo: "faltavam plano,
-- episódio e requisições". As requisições são o que liga o diagnóstico médico
-- do fisiatra ao resto do sistema de saúde (entrada #001: "puxa meios
-- complementares de diagnóstico").
--
-- Regra de segurança clínica que aqui se materializa: só quem pode prescrever
-- (profissionais.prescritor) assina uma requisição ou receita. A app valida,
-- mas a base de dados é quem garante.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Requisições (MCDT, terapias, consultas de especialidade)
-- ---------------------------------------------------------------------------
create table if not exists public.requisicoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  diagnostico_id    uuid references public.diagnosticos(id) on delete set null,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,

  numero            text,                     -- referência interna legível: REQ-2026-000123
  tipo              public.requisicao_tipo not null,
  estado            public.requisicao_estado not null default 'rascunho',
  prioridade        text not null default 'normal',   -- normal | urgente | muito_urgente

  -- O que se pede. Estruturado quando é catálogo, livre quando é específico.
  descricao         text not null,
  codigo            text,                     -- código do exame/procedimento
  itens             jsonb not null default '[]'::jsonb,
    -- [{codigo:"70.20", designacao:"RM coluna lombar s/ contraste", quantidade:1,
    --   regiao:"lombar", observacoes:"protocolo funcional"}]
  indicacao_clinica text,                     -- justificação: é isto que o radiologista lê
  questao_a_responder text,                   -- pergunta clínica concreta
  -- Destino
  entidade_destino  text,
  medico_destino    text,
  contacto_destino  text,

  -- Documento emitido (PDF assinado, no Storage UE)
  documento_url     text,
  documento_hash    text,

  -- Quem pede TEM de ser prescritor
  solicitado_por    uuid references public.profissionais(id) on delete set null,
  solicitado_em     timestamptz,
  -- Controlo do ciclo de vida
  enviada_em        timestamptz,
  realizada_em      date,
  resultado_recebido_em timestamptz,
  resultado         text,
  resultado_anexos  jsonb not null default '[]'::jsonb,
  resultado_interpretacao text,
  motivo_cancelamento text,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint requisicoes_descricao_nao_vazia check (length(btrim(descricao)) > 0),
  constraint requisicoes_prioridade_valida
    check (prioridade in ('normal','urgente','muito_urgente')),
  constraint requisicoes_emitida_tem_autor
    check (estado = 'rascunho' or solicitado_por is not null),
  constraint requisicoes_numero_unico unique (clinica_id, numero)
);

create index if not exists idx_requisicoes_utente  on public.requisicoes (utente_id, created_at desc);
create index if not exists idx_requisicoes_episodio on public.requisicoes (episodio_id);
create index if not exists idx_requisicoes_estado  on public.requisicoes (clinica_id, estado);
create index if not exists idx_requisicoes_tipo    on public.requisicoes (clinica_id, tipo);

drop trigger if exists t_requisicoes_updated_at on public.requisicoes;
create trigger t_requisicoes_updated_at
  before update on public.requisicoes
  for each row execute function clinia.set_updated_at();

comment on table public.requisicoes is
  'MCDT, terapias e consultas pedidas. Liga o diagnóstico médico ao sistema de saúde.';

-- ---------------------------------------------------------------------------
-- 2. Prescrições (medicação, ajudas técnicas, meios auxiliares)
-- ---------------------------------------------------------------------------
create table if not exists public.prescricoes (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  diagnostico_id    uuid references public.diagnosticos(id) on delete set null,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,

  numero            text,
  tipo              public.prescricao_tipo not null default 'medicacao',
  estado            public.requisicao_estado not null default 'rascunho',

  -- Medicação
  medicamento       text,
  dci               text,                     -- denominação comum internacional
  dosagem           text,                     -- "500 mg"
  forma             text,                     -- comprimido, gel, pomada
  posologia         text,                     -- "1 comp. 8/8h, 7 dias"
  via               text,
  duracao           text,
  quantidade        text,
  -- Ajuda técnica / meio auxiliar
  dispositivo       text,                     -- "canadiana", "ortótese tornozelo-pé"
  referencia        text,
  medidas           text,
  lateralidade      text,

  indicacao         text,
  observacoes       text,
  -- Medicamentos sujeitos a receita especial mantêm o seu regime legal
  receita_especial  boolean not null default false,
  valida_ate        date,
  documento_url     text,

  prescrito_por     uuid references public.profissionais(id) on delete set null,
  prescrito_em      timestamptz,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  -- Coerência entre tipo e conteúdo: uma prescrição de medicação sem
  -- medicamento é um erro que chega à farmácia.
  constraint prescricoes_conteudo_coerente
    check (
      (tipo = 'medicacao'  and medicamento is not null)
      or (tipo in ('ajuda_tecnica','meio_auxiliar_de_marcha') and dispositivo is not null)
      or (tipo in ('terapia','analitica','outro'))
    ),
  constraint prescricoes_emitida_tem_autor
    check (estado = 'rascunho' or prescrito_por is not null),
  constraint prescricoes_numero_unico unique (clinica_id, numero)
);

create index if not exists idx_prescricoes_utente  on public.prescricoes (utente_id, created_at desc);
create index if not exists idx_prescricoes_episodio on public.prescricoes (episodio_id);
create index if not exists idx_prescricoes_estado  on public.prescricoes (clinica_id, estado);

drop trigger if exists t_prescricoes_updated_at on public.prescricoes;
create trigger t_prescricoes_updated_at
  before update on public.prescricoes
  for each row execute function clinia.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Relatórios e notas
-- ---------------------------------------------------------------------------
create table if not exists public.relatorios (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,

  tipo              public.relatorio_tipo not null default 'nota_clinica',
  estado            public.relatorio_estado not null default 'rascunho',
  titulo            text,
  assunto           text,
  conteudo          text,
  -- Estrutura do relatório, para os campos obrigatórios por tipo (seguradora,
  -- médico-legal) serem validáveis
  secoes            jsonb not null default '[]'::jsonb,
  destinatario      text,
  data_relatorio    date not null default current_date,
  periodo_inicio    date,
  periodo_fim       date,

  documento_url     text,
  documento_hash    text,
  assinado_por      uuid references public.profissionais(id) on delete set null,
  assinado_em       timestamptz,
  entregue_em       timestamptz,
  entregue_a        text,

  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint relatorios_assinado_tem_autor
    check (estado not in ('assinado','entregue') or (assinado_por is not null and assinado_em is not null)),
  constraint relatorios_periodo_coerente
    check (periodo_fim is null or periodo_inicio is null or periodo_fim >= periodo_inicio)
);

create index if not exists idx_relatorios_utente   on public.relatorios (utente_id, data_relatorio desc);
create index if not exists idx_relatorios_episodio on public.relatorios (episodio_id);
create index if not exists idx_relatorios_tipo     on public.relatorios (clinica_id, tipo, estado);

drop trigger if exists t_relatorios_updated_at on public.relatorios;
create trigger t_relatorios_updated_at
  before update on public.relatorios
  for each row execute function clinia.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Media (imagem, vídeo, áudio, documentos)
--    Ficheiros vivem no Storage (UE). A base de dados guarda metadados e o
--    vínculo clínico — é o vínculo que dá valor legal e clínico ao ficheiro.
-- ---------------------------------------------------------------------------
create table if not exists public.media (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  utente_id         uuid not null references public.utentes(id) on delete restrict,
  episodio_id       uuid references public.episodios(id) on delete restrict,
  ato_id            uuid references public.atos_clinicos(id) on delete set null,
  diagnostico_id    uuid references public.diagnosticos(id) on delete set null,

  tipo              text not null default 'documento',
    -- fotografia | video | audio | radiologia | ecografia | documento | outro
  categoria         text,     -- avaliacao_marcha | ferida | postura | resultado_exame
  nome_ficheiro     text not null,
  descricao         text,
  bucket            text not null default 'clinica-media',
  caminho           text not null,          -- caminho no Storage
  mime_type         text,
  tamanho_bytes     bigint,
  largura           integer,
  altura            integer,
  duracao_segundos  integer,
  -- Imagem clínica é dado sensível: hash para integridade e data para contexto
  hash_ficheiro     text,
  data_captura      date,
  regiao            text,
  lado              text,
  consentimento_id  uuid references public.consentimentos(id) on delete set null,
  visivel_utente    boolean not null default false,

  capturado_por     uuid references public.profissionais(id) on delete set null,
  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint media_tipo_valido
    check (tipo in ('fotografia','video','audio','radiologia','ecografia','documento','outro')),
  constraint media_tamanho_positivo check (tamanho_bytes is null or tamanho_bytes > 0),
  constraint media_caminho_nao_vazio check (length(btrim(caminho)) > 0)
);

create index if not exists idx_media_utente   on public.media (utente_id, created_at desc);
create index if not exists idx_media_episodio on public.media (episodio_id, tipo);
create index if not exists idx_media_ato      on public.media (ato_id);
create index if not exists idx_media_caminho  on public.media (bucket, caminho);

drop trigger if exists t_media_updated_at on public.media;
create trigger t_media_updated_at
  before update on public.media
  for each row execute function clinia.set_updated_at();

comment on table public.media is
  'Metadados de ficheiros no Storage (UE). Guarda o vínculo clínico, não o ficheiro.';

-- ---------------------------------------------------------------------------
-- 5. Modelos de documento (templates)
--    O blueprint prevê templates de relatório no contrato de módulo. Guardados
--    como dados para a clínica poder afinar os seus sem nova versão da app.
-- ---------------------------------------------------------------------------
create table if not exists public.modelos_documento (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid references public.clinicas(id) on delete cascade,   -- null = global
  codigo            text not null,
  nome              text not null,
  tipo              public.relatorio_tipo not null default 'nota_clinica',
  especialidade     public.especialidade not null default 'mfr',
  -- Corpo com marcadores {{utente.nome}}, {{episodio.queixa}}...
  corpo             text not null,
  secoes_obrigatorias text[] not null default '{}',
  cabecalho         text,
  rodape            text,
  incluir_logotipo  boolean not null default true,
  versao            text not null default '1.0',
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create unique index if not exists uq_modelos_documento_global
  on public.modelos_documento (codigo, versao) where clinica_id is null;
create unique index if not exists uq_modelos_documento_clinica
  on public.modelos_documento (clinica_id, codigo, versao) where clinica_id is not null;

drop trigger if exists t_modelos_documento_updated_at on public.modelos_documento;
create trigger t_modelos_documento_updated_at
  before update on public.modelos_documento
  for each row execute function clinia.set_updated_at();


-- ----------------------------------------------------------------------------
-- 0010_rls_auditoria.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0010 — Acesso, RLS multi-tenant e auditoria RGPD
--
-- O protótipo tinha RLS ligado com a política `using (true)`: qualquer
-- autenticado lia tudo. Para dados de saúde (RGPD art. 9) isso é indefensável.
--
-- Modelo de acesso:
--   · ADMINISTRADOR / GESTAO  -> todo o tenant
--   · RECECAO                 -> utentes + agenda (sem conteúdo clínico)
--   · PERFIS CLINICOS         -> todo o tenant clínico; escrevem atos e registos
--   · UTENTE                  -> apenas os seus próprios dados (portal)
--
-- Nota técnica importante: as funções auxiliares são SECURITY DEFINER e são
-- propriedade do owner do schema. É isso que evita a recursão infinita em RLS
-- (uma política em perfis que consulta perfis) e o custo de avaliar a subquery
-- por cada linha. Não se ativa FORCE ROW LEVEL SECURITY de propósito: o owner
-- (migrations) tem de poder correr sem políticas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Ligação conta de portal -> utente
--
-- Esta coluna tem de existir ANTES das funções abaixo: o corpo das funções
-- PL/pgSQL é validado na criação (check_function_bodies), e
-- clinia.current_utente_id() lê perfis.utente_id. Declarar a coluna depois
-- dava "column p.utente_id does not exist" — que foi exatamente o erro que a
-- validação automática apanhou.
-- ---------------------------------------------------------------------------
alter table public.perfis
  add column if not exists utente_id uuid;

alter table public.perfis
  drop constraint if exists perfis_utente_fk;
alter table public.perfis
  add constraint perfis_utente_fk
  foreign key (utente_id) references public.utentes(id) on delete set null;

create index if not exists idx_perfis_utente on public.perfis (utente_id);

-- ---------------------------------------------------------------------------
-- 1. Contexto do utilizador autenticado
-- ---------------------------------------------------------------------------
create or replace function clinia.current_clinica_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.clinica_id
    from public.perfis p
   where p.id = auth.uid()
     and p.ativo
   limit 1;
$$;

create or replace function clinia.current_perfil()
returns public.perfil_tipo
language sql
stable
security definer
set search_path = public
as $$
  select p.perfil
    from public.perfis p
   where p.id = auth.uid()
     and p.ativo
   limit 1;
$$;

-- Quem exerce clínica. Só estes veem e escrevem conteúdo clínico.
create or replace function clinia.e_clinico()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil in ('administrador','fisiatra','fisioterapeuta','osteopata',
                        'terapeuta_ocupacional','terapeuta_da_fala','psicologo','enfermeiro')
  );
$$;

create or replace function clinia.e_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil in ('administrador','gestao')
  );
$$;

-- Receção precisa de gerir utentes e agenda, mas não de ler diagnóstico.
create or replace function clinia.e_rececao_ou_melhor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil in ('administrador','gestao','rececao',
                        'fisiatra','fisioterapeuta','osteopata',
                        'terapeuta_ocupacional','terapeuta_da_fala','psicologo','enfermeiro')
  );
$$;

-- O profissional de saúde correspondente à conta autenticada.
create or replace function clinia.current_profissional_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select pr.id
    from public.profissionais pr
   where pr.perfil_id = auth.uid()
   limit 1;
$$;

-- É portal do utente? A conta de utente liga-se pelo próprio id.
create or replace function clinia.e_portal_utente()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid() and p.ativo and p.perfil = 'utente'
  );
$$;

-- Utente associado à conta autenticada (portal). Lê de perfis.utente_id, campo
-- que existe para ligar uma conta de portal ao processo clínico.
create or replace function clinia.current_utente_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.utente_id
    from public.perfis p
   where p.id = auth.uid()
   limit 1;
$$;

comment on function clinia.current_clinica_id() is
  'clinica_id da conta autenticada. Base do isolamento multi-tenant.';

-- ---------------------------------------------------------------------------
-- 2. (A coluna utente_id e a sua FK foram movidas para o topo deste ficheiro,
--     antes das funções que as referenciam. Ver secção 0.)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. Auditoria (RGPD)
--    Append-only por desenho: NÃO tem política de UPDATE nem DELETE. Mesmo que
--    alguém tente, o RLS recusa. Uma auditoria que se pode editar não é prova.
-- ---------------------------------------------------------------------------
create table if not exists public.audit_log (
  id                bigserial primary key,
  clinica_id        uuid,
  utente_id         uuid,
  ator_id           uuid,
  ator_nome         text,
  ator_perfil       public.perfil_tipo,
  operacao          public.audit_operacao not null,
  entidade          text not null,
  registo_id        text,
  dados_antes       jsonb,
  dados_depois      jsonb,
  campos_alterados  text[],
  -- Contexto técnico: obrigatório em auditoria com valor probatório
  ip                inet,
  user_agent        text,
  origem            text,
  sucesso           boolean not null default true,
  detalhe           text,
  created_at        timestamptz not null default now()
);

create index if not exists idx_audit_clinica   on public.audit_log (clinica_id, created_at desc);
create index if not exists idx_audit_ator      on public.audit_log (ator_id, created_at desc);
create index if not exists idx_audit_entidade  on public.audit_log (entidade, registo_id);
create index if not exists idx_audit_utente    on public.audit_log (utente_id, created_at desc);
create index if not exists idx_audit_operacao  on public.audit_log (operacao, created_at desc);

comment on table public.audit_log is
  'Registo de auditoria append-only (RGPD art. 30). Sem UPDATE nem DELETE por política.';

-- ---------------------------------------------------------------------------
-- 4. Gatilho genérico de auditoria para tabelas clínicas
--    Guardar o antes e o depois é o que permite responder a "quem mudou isto e
--    quando" — a pergunta que aparece sempre numa reclamação ou auditoria.
-- ---------------------------------------------------------------------------
create or replace function clinia.auditar()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_antes    jsonb;
  v_depois   jsonb;
  v_campos   text[];
  v_clinica  uuid;
  v_utente   uuid;
  v_registo  text;
  v_operacao public.audit_operacao;
begin
  if tg_op = 'INSERT' then
    v_operacao := 'insert';
    v_depois   := to_jsonb(new);
    v_registo  := new.id::text;
  elsif tg_op = 'UPDATE' then
    v_operacao := 'update';
    v_antes    := to_jsonb(old);
    v_depois   := to_jsonb(new);
    v_registo  := new.id::text;
    -- Só os campos que realmente mudaram: um diff completo é ruído ilegível.
    select array_agg(key order by key)
      into v_campos
      from jsonb_each(v_depois) d
     where d.value is distinct from (v_antes -> d.key);
  else
    v_operacao := 'delete';
    v_antes    := to_jsonb(old);
    v_registo  := old.id::text;
  end if;

  -- Extrai clinica_id/utente_id quando a tabela os tem; a auditoria não deve
  -- rebentar por uma tabela de catálogo não os ter.
  begin
    v_clinica := coalesce((v_depois ->> 'clinica_id')::uuid, (v_antes ->> 'clinica_id')::uuid);
    v_utente  := coalesce((v_depois ->> 'utente_id')::uuid,  (v_antes ->> 'utente_id')::uuid);
  exception when others then
    v_clinica := null;
    v_utente  := null;
  end;

  insert into public.audit_log (
    clinica_id, utente_id, ator_id, ator_nome, ator_perfil,
    operacao, entidade, registo_id, dados_antes, dados_depois, campos_alterados,
    ip, user_agent, origem
  ) values (
    v_clinica, v_utente, auth.uid(),
    (select p.nome from public.perfis p where p.id = auth.uid()),
    (select p.perfil from public.perfis p where p.id = auth.uid()),
    v_operacao, tg_table_name, v_registo, v_antes, v_depois, v_campos,
    -- Contexto do pedido, dos headers do PostgREST. Se não existir (migração
    -- corrida no SQL Editor, por exemplo) fica null em vez de rebentar.
    --
    -- O x-forwarded-for pode trazer uma lista ("cliente, proxy") e a coluna é
    -- inet: ficamos com o primeiro endereço e só convertemos se for válido.
    -- Uma auditoria que rebenta por causa de um header malformado perderia o
    -- registo — e uma auditoria com falhas não serve para nada.
    case
      when nullif(current_setting('request.headers', true), '') is null then null
      when split_part(
             nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-forwarded-for',
             ',', 1) ~ '^[0-9a-fA-F:.]+$'
        then split_part(
               nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-forwarded-for',
               ',', 1)::inet
      else null
    end,
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent',
    nullif(current_setting('clinia.origem', true), '')
  );

  return coalesce(new, old);
end $$;

-- Aplicar auditoria às tabelas onde o histórico é obrigatório.
do $$
declare
  t text;
  tabelas text[] := array[
    'utentes', 'consentimentos', 'episodios', 'diagnosticos', 'episodio_cif',
    'atos_clinicos', 'mfr_avaliacao_dor', 'mfr_movimento', 'mfr_avaliacao_funcao',
    'sessoes', 'medicoes', 'planos', 'plano_objetivos', 'criterios_alta',
    'requisicoes', 'prescricoes', 'relatorios', 'media'
  ];
begin
  foreach t in array tabelas loop
    execute format('drop trigger if exists t_audit_%1$s on public.%1$I;', t);
    execute format(
      'create trigger t_audit_%1$s after insert or update or delete on public.%1$I
         for each row execute function clinia.auditar();', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Ativar RLS e conceder privilégios
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  -- Todas as tabelas de dados do schema public criadas por estas migrações.
  tabelas text[] := array[
    'clinicas','perfis','profissionais',
    'utentes','utente_contactos','consentimentos',
    'episodios','diagnosticos','episodio_cif',
    'cif_catalogo','cid_catalogo','regioes_anatomicas','articulacoes','tipos_medicao',
    'agendamentos','atos_clinicos','escalas','escala_itens',
    'mfr_avaliacao_dor','mfr_movimento','mfr_avaliacao_funcao','medicoes',
    'mfr_escala_aplicada','mfr_observacoes','sessoes',
    'planos','plano_objetivos','criterios_alta','objetivo_progresso',
    'exercicios','hep_prescricoes','hep_exercicios',
    'requisicoes','prescricoes','relatorios','media','modelos_documento',
    'audit_log',
    -- Acrescentadas na migração 0013 (produtos e módulos). A lista é fixa, por
    -- isso uma tabela nova tem de ser inscrita aqui para receber os grants.
    'modulos','clinica_modulos'
  ];
begin
  foreach t in array tabelas loop
    -- Só se a tabela existir nesta altura.
    --
    -- A lista acima inclui tabelas criadas por migrações POSTERIORES a esta
    -- (0013). Sem esta guarda, um `alter table` sobre uma tabela que ainda não
    -- existe rebentava a instalação — e a lista deixaria de poder ser mantida
    -- atualizada com os grants, que é justamente o que interessa.
    --
    -- A verificação é feita no catálogo em vez de se recorrer a `to_regclass`
    -- para não depender da forma como o nome é resolvido no search_path.
    if exists (
      select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = t and c.relkind in ('r', 'p')
    ) then
      execute format('alter table public.%I enable row level security;', t);
      execute format('grant select, insert, update, delete on public.%I to authenticated;', t);
      execute format('grant all on public.%I to service_role;', t);
    end if;
  end loop;
end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema clinia to authenticated, service_role;

-- As funções utilitárias fazem SELECT a perfis; sem este grant o cliente não as
-- pode invocar diretamente (a app usa-as em filtros).
grant execute on all functions in schema clinia to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Políticas — catálogos partilhados e de tenant
-- ---------------------------------------------------------------------------
drop policy if exists clinicas_select on public.clinicas;
create policy clinicas_select on public.clinicas
  for select to authenticated
  using (id = clinia.current_clinica_id() or clinia.e_admin());

drop policy if exists clinicas_admin on public.clinicas;
create policy clinicas_admin on public.clinicas
  for all to authenticated
  using (id = clinia.current_clinica_id() and clinia.e_admin())
  with check (id = clinia.current_clinica_id() and clinia.e_admin());

-- Perfis: cada um vê o seu; admin vê os do tenant.
drop policy if exists perfis_select on public.perfis;
create policy perfis_select on public.perfis
  for select to authenticated
  using (id = auth.uid()
         or (clinica_id = clinia.current_clinica_id() and clinia.e_admin()));

drop policy if exists perfis_update_proprio on public.perfis;
create policy perfis_update_proprio on public.perfis
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and clinica_id = clinia.current_clinica_id());

drop policy if exists perfis_admin on public.perfis;
create policy perfis_admin on public.perfis
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_admin())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_admin());

-- Profissionais: toda a equipa precisa de ver o diretório (dropdowns).
drop policy if exists profissionais_select on public.profissionais;
create policy profissionais_select on public.profissionais
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id());

drop policy if exists profissionais_write on public.profissionais;
create policy profissionais_write on public.profissionais
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

-- Catálogos globais (CIF, CID): leitura para todos, escrita só ao service_role.
do $$
declare t text;
  catalogos text[] := array[
    'cif_catalogo','cid_catalogo','regioes_anatomicas','articulacoes'
  ];
begin
  foreach t in array catalogos loop
    execute format('drop policy if exists %1$s_select on public.%1$I;', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated
                      using (true);', t);
    execute format('drop policy if exists %1$s_write on public.%1$I;', t);
    execute format('create policy %1$s_write on public.%1$I for all to authenticated
                      using (clinia.e_admin()) with check (clinia.e_admin());', t);
  end loop;
end $$;

-- Tipos de medição, escalas e exercícios: globais (clinica_id null) ou do tenant.
do $$
declare t text;
  mistas text[] := array['tipos_medicao','escalas','exercicios','modelos_documento'];
begin
  foreach t in array mistas loop
    execute format('drop policy if exists %1$s_select on public.%1$I;', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated
                      using (clinica_id is null or clinica_id = clinia.current_clinica_id());', t);
    execute format('drop policy if exists %1$s_write on public.%1$I;', t);
    execute format('create policy %1$s_write on public.%1$I for all to authenticated
                      using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
                      with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());', t);
  end loop;
end $$;

-- Escala de itens herda a visibilidade da escala.
drop policy if exists escala_itens_select on public.escala_itens;
create policy escala_itens_select on public.escala_itens
  for select to authenticated
  using (exists (
    select 1 from public.escalas e
     where e.id = escala_itens.escala_id
       and (e.clinica_id is null or e.clinica_id = clinia.current_clinica_id())
  ));

-- ---------------------------------------------------------------------------
-- 7. Políticas — dados de utente e clínicos
--    Padrão: isolamento por clinica_id + exigência de papel clínico onde o
--    conteúdo é sensível.
-- ---------------------------------------------------------------------------
-- utentes: a receção (e acima) gere; o portal do utente lê apenas o seu registo.
-- utentes é a própria entidade, por isso a comparação é com id, não com utente_id.
drop policy if exists utentes_select on public.utentes;
create policy utentes_select on public.utentes
  for select to authenticated
  using ((clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
         or (clinia.e_portal_utente() and id = clinia.current_utente_id()));

drop policy if exists utentes_write on public.utentes;
create policy utentes_write on public.utentes
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor());

-- utente_contactos: dados de contacto de familiares/cuidadores.
drop policy if exists utente_contactos_select on public.utente_contactos;
create policy utente_contactos_select on public.utente_contactos
  for select to authenticated
  using ((clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
         or (clinia.e_portal_utente() and utente_id = clinia.current_utente_id()));

drop policy if exists utente_contactos_write on public.utente_contactos;
create policy utente_contactos_write on public.utente_contactos
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor());

-- Consentimentos: leitura para a equipa e para o próprio utente; escrita APENAS
-- por INSERT. Sem política de UPDATE nem DELETE: revoga-se criando novo registo,
-- porque o histórico de consentimento é prova legal (RGPD art. 7.º).
drop policy if exists consentimentos_select on public.consentimentos;
create policy consentimentos_select on public.consentimentos
  for select to authenticated
  using ((clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
         or (clinia.e_portal_utente() and utente_id = clinia.current_utente_id()));

drop policy if exists consentimentos_insert on public.consentimentos;
create policy consentimentos_insert on public.consentimentos
  for insert to authenticated
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor());

-- Tabelas clínicas: só perfis clínicos. A receção não lê diagnósticos.
--
-- O loop DESCOBRE se a tabela tem utente_id em vez de o assumir. Duas tabelas
-- deste grupo (criterios_alta, objetivo_progresso) não têm a coluna — são
-- satélites que se ligam por objetivo_id e por ato_id — e assumir a coluna
-- fazia a migração falhar. Uma lista de tabelas que tem de estar sincronizada
-- com o schema é uma armadilha; a pergunta ao catálogo não é.
do $$
declare
  t          text;
  tem_utente boolean;
  clinicas   text[] := array[
    'episodios','diagnosticos','episodio_cif',
    'atos_clinicos','mfr_avaliacao_dor','mfr_movimento','mfr_avaliacao_funcao',
    'medicoes','mfr_escala_aplicada','mfr_observacoes','sessoes',
    'planos','plano_objetivos','criterios_alta','objetivo_progresso',
    'requisicoes','prescricoes','relatorios','media','hep_prescricoes'
  ];
begin
  foreach t in array clinicas loop
    select exists (
      select 1 from pg_attribute a
       where a.attrelid = format('public.%I', t)::regclass
         and a.attname = 'utente_id'
         and a.attnum > 0
         and not a.attisdropped
    ) into tem_utente;

    execute format('drop policy if exists %1$s_select on public.%1$I;', t);
    -- Tabelas satélite sem utente_id (criterios_alta, objetivo_progresso) não
    -- têm política de portal: o utente chega-lhes pelo episódio, não por aqui.
    -- A comparação tem de ser com uma coluna uuid, nunca com um literal
    -- booleano — foi esse o erro que a validação apanhou.
    execute format(
      'create policy %1$s_select on public.%1$I for select to authenticated
         using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico()
                or (clinia.e_portal_utente() and %2$s));',
      t,
      case when tem_utente
           then 'utente_id = clinia.current_utente_id()'
           else 'false' end);

    execute format('drop policy if exists %1$s_write on public.%1$I;', t);
    execute format(
      'create policy %1$s_write on public.%1$I for all to authenticated
         using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
         with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());', t);
  end loop;
end $$;

-- episodios tem utente_id, por isso a política dupla do loop acima já cobre o
-- clínico do tenant e o portal do próprio utente.

-- hep_exercicios passou a ser tratada pelo loop acima (tem utente_id), o que lhe
-- dá também acesso pelo portal do utente. As políticas explícitas que aqui
-- estavam foram removidas por serem redundantes: duas políticas permissivas na
-- mesma tabela somam-se, e a mais restritiva deixaria de proteger nada.

-- Agenda: a receção marca; todos os clínicos veem a agenda do tenant.
drop policy if exists agendamentos_select on public.agendamentos;
create policy agendamentos_select on public.agendamentos
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor());

drop policy if exists agendamentos_write on public.agendamentos;
create policy agendamentos_write on public.agendamentos
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_rececao_ou_melhor());

-- ---------------------------------------------------------------------------
-- 8. Auditoria: só se lê, e só o admin do tenant. Sem UPDATE/DELETE.
-- ---------------------------------------------------------------------------
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_admin());

drop policy if exists audit_log_insert on public.audit_log;
create policy audit_log_insert on public.audit_log
  for insert to authenticated
  with check (true);

-- O acesso direto do cliente à auditoria é de leitura; a escrita é feita pelo
-- gatilho (SECURITY DEFINER). Revoga-se explicitamente o resto.
revoke update, delete on public.audit_log from authenticated;

comment on policy audit_log_select on public.audit_log is
  'Auditoria visível apenas ao administrador do tenant, em leitura.';

-- ---------------------------------------------------------------------------
-- 9. Utilitário para a app: perfil efetivo do utilizador autenticado
--    Um único pedido em vez de três, no arranque da aplicação.
-- ---------------------------------------------------------------------------
create or replace view public.vw_meu_contexto as
  select p.id                as perfil_id,
         p.nome,
         p.email,
         p.perfil,
         p.especialidade,
         p.clinica_id,
         c.nome              as clinica_nome,
         c.especialidades,
         p.utente_id,
         clinia.e_clinico()  as e_clinico,
         clinia.e_admin()    as e_admin,
         p.preferencias
    from public.perfis p
    left join public.clinicas c on c.id = p.clinica_id
   where p.id = auth.uid();

comment on view public.vw_meu_contexto is
  'Contexto do utilizador autenticado. Chamado uma vez no arranque da app.';


-- ----------------------------------------------------------------------------
-- 0011_integridade_clinica.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0011 — Integridade clínica e indicadores
--
-- Aqui fecham-se as regras que, se ficassem só no cliente, seriam contornáveis
-- ou — pior — esquecidas numa reescrita da app. Regra de ouro: o que é uma
-- obrigação clínica ou legal vive na base de dados.
--
-- Lição do schema v1 (entrada #002): "ON DELETE RESTRICT + soft-delete
-- (arquivado) — não se apaga histórico clínico em cascata."
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Numeração legível (utentes, episódios, requisições, prescrições)
--    Um número que o utente pode dizer ao telefone vale mais do que um uuid.
-- ---------------------------------------------------------------------------
create sequence if not exists public.requisicao_numero_seq start 1;
create sequence if not exists public.prescricao_numero_seq start 1;

-- As funções de gatilho NÃO podem ter argumentos declarados (regra do
-- PostgreSQL: "trigger functions cannot have declared arguments"). Os
-- parâmetros chegam por TG_ARGV, declarados no CREATE TRIGGER.
create or replace function clinia.gerar_numero()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_seq     text := tg_argv[0];
  v_prefixo text := tg_argv[1];
  v_ano     text := to_char(coalesce(new.created_at, now()), 'YYYY');
  v_num     integer;
begin
  if v_seq is null or v_prefixo is null then
    raise exception 'Gatilho de numeração mal configurado em %', tg_table_name;
  end if;

  -- Um número já atribuído (ex.: importação) nunca é substituído.
  if new.numero is not null then
    return new;
  end if;

  v_num := nextval('public.' || v_seq);
  new.numero := v_prefixo || '-' || v_ano || '-' || lpad(v_num::text, 6, '0');
  return new;
end $$;

drop trigger if exists t_requisicoes_numero on public.requisicoes;
create trigger t_requisicoes_numero
  before insert on public.requisicoes
  for each row execute function clinia.gerar_numero('requisicao_numero_seq', 'REQ');

drop trigger if exists t_prescricoes_numero on public.prescricoes;
create trigger t_prescricoes_numero
  before insert on public.prescricoes
  for each row execute function clinia.gerar_numero('prescricao_numero_seq', 'REC');

-- ---------------------------------------------------------------------------
-- 2. Campos de autoria preenchidos automaticamente
--    Se depender do cliente, metade dos registos fica sem autor — e sem autor
--    não há responsabilidade clínica atribuível.
-- ---------------------------------------------------------------------------
create or replace function clinia.preencher_autoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.created_by is null then
      new.created_by := auth.uid();
    end if;
  end if;

  if tg_op = 'UPDATE' and to_jsonb(new) ? 'updated_by' then
    new.updated_by := auth.uid();
  end if;

  return new;
end $$;

-- Aplicar a autoria a TODAS as tabelas que tenham created_by, descobertas no
-- catálogo. Uma lista escrita à mão desatualiza-se em silêncio à medida que o
-- schema cresce, e o sintoma (campos de autor vazios) só aparece meses depois.
do $$
declare
  r record;
begin
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'created_by'
                      and a.attnum > 0 and not a.attisdropped)
  loop
    execute format('drop trigger if exists t_%1$s_autoria on public.%1$I;', r.relname);
    execute format(
      'create trigger t_%1$s_autoria before insert or update on public.%1$I
         for each row execute function clinia.preencher_autoria();', r.relname);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Soft-delete: substituir DELETE por arquivo
--    O cliente que tenta apagar um utente ou uma sessão está, na verdade, a
--    arquivá-lo. Isto evita perda acidental de histórico clínico e mantém as
--    chaves estrangeiras intactas.
-- ---------------------------------------------------------------------------
create or replace function clinia.arquivar_em_vez_de_apagar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  execute format('update public.%I set arquivado_em = now() where id = $1', tg_table_name)
    using old.id;
  return null;
end $$;

-- Converte DELETE em arquivo em todas as tabelas que tenham arquivado_em,
-- descobertas no catálogo. A lista escrita à mão que aqui estava incluía tabelas
-- sem a coluna (sessoes, episodio_cif) e falhava no primeiro DELETE — foi a
-- validação automática que o apanhou, ao testar "apagar uma sessão".
do $$
declare
  r record;
begin
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'arquivado_em'
                      and a.attnum > 0 and not a.attisdropped)
  loop
    execute format('drop trigger if exists t_%1$s_soft_delete on public.%1$I;', r.relname);
    execute format(
      'create trigger t_%1$s_soft_delete before delete on public.%1$I
         for each row execute function clinia.arquivar_em_vez_de_apagar();', r.relname);
  end loop;
end $$;

comment on function clinia.arquivar_em_vez_de_apagar() is
  'Converte DELETE em arquivo (arquivado_em). Histórico clínico não se apaga.';

-- ---------------------------------------------------------------------------
-- 4. Imutabilidade de registos assinados
--    Um ato assinado é um documento. Alterá-lo depois é falsificação, mesmo
--    que bem-intencionada. O caminho correto é retificar: novo ato que
--    referencia o anterior. A app mostra os dois.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_ato_assinado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ignorar text[] := array[
    'updated_at','updated_by','arquivado_em','retifica_ato_id','retificado_motivo',
    'estado','assinado_por','assinado_em','assinatura_hash','sessao_id'
  ];
  v_campo text;
begin
  if old.estado not in ('assinado','retificado') then
    return new;
  end if;

  -- Percorre os campos alterados e recusa se algum for conteúdo clínico.
  for v_campo in
    select key from jsonb_each(to_jsonb(new)) n
     where n.value is distinct from (to_jsonb(old) -> n.key)
  loop
    if not (v_campo = any (v_ignorar)) then
      raise exception
        'Ato assinado não pode ser alterado (campo "%"). Retifique com um novo ato.', v_campo
        using errcode = 'check_violation';
    end if;
  end loop;

  return new;
end $$;

drop trigger if exists t_atos_proteger_assinado on public.atos_clinicos;
create trigger t_atos_proteger_assinado
  before update on public.atos_clinicos
  for each row execute function clinia.proteger_ato_assinado();

comment on function clinia.proteger_ato_assinado() is
  'Impede alteração de conteúdo de atos assinados. Obriga a retificação rastreada.';

-- Assinatura: preenche autor, data e impressão digital do conteúdo.
create or replace function clinia.assinar_ato()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_autor uuid;
begin
  if new.estado in ('assinado','retificado') and old.estado = 'rascunho' then
    -- Quem assina: a conta autenticada. Se não houver sessão (migração ou
    -- script corrido no SQL Editor), cai para quem criou o ato — e se também
    -- não houver, a assinatura é recusada. A regra "um ato assinado tem autor
    -- identificado" tem de ser verdadeira, e aqui é o único sítio onde ainda
    -- pode ser imposta.
    v_autor := coalesce(auth.uid(), new.created_by, old.created_by);

    if v_autor is null then
      raise exception
        'Não é possível assinar um ato sem autor identificado (sem sessão ativa e sem created_by).'
        using errcode = 'check_violation';
    end if;

    new.assinado_em := coalesce(new.assinado_em, now());
    new.assinado_por := coalesce(new.assinado_por, v_autor);

    -- Impressão digital do conteúdo clínico no momento da assinatura: permite
    -- provar mais tarde que o documento não foi alterado.
    new.assinatura_hash := encode(
      digest(
        coalesce(new.id::text,'') || coalesce(new.utente_id::text,'') ||
        coalesce(new.episodio_id::text,'') || coalesce(new.tipo::text,'') ||
        coalesce(new.fase,'') || coalesce(new.dados::text,'') ||
        coalesce(new.observacoes,'') || coalesce(new.assinado_em::text,''),
        'sha256'
      ), 'hex');
  end if;
  return new;
end $$;

drop trigger if exists t_atos_assinar on public.atos_clinicos;
create trigger t_atos_assinar
  before update on public.atos_clinicos
  for each row execute function clinia.assinar_ato();

-- ---------------------------------------------------------------------------
-- 5. Coerência entre clínica e utente
--    Um erro clássico e silencioso: um registo clínico apontar para um utente
--    de outra clínica. O RLS esconde-o, mas o dado fica errado para sempre.
--
--    O gatilho é genérico e é aplicado a tabelas que NÃO têm todas utente_id
--    (criterios_alta e objetivo_progresso ligam-se por objetivo_id). Referir
--    new.utente_id diretamente dava "record new has no field utente_id" — erro
--    que a validação automática apanhou. A solução é perguntar ao catálogo, em
--    tempo de execução, se a coluna existe na tabela que disparou o gatilho.
-- ---------------------------------------------------------------------------
create or replace function clinia.validar_coerencia_clinica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tem_utente boolean;
  v_utente     uuid;
  v_clinica    uuid;
  v_utente_clinica uuid;
begin
  select exists (
    select 1 from pg_attribute a
     where a.attrelid = tg_relid
       and a.attname = 'utente_id'
       and a.attnum > 0
       and not a.attisdropped
  ) into v_tem_utente;

  -- Tabela sem utente_id: nada a validar aqui.
  if not v_tem_utente then
    return new;
  end if;

  -- Extrair os dois campos por SQL dinâmico. É preciso porque a coluna pode não
  -- existir em algumas tabelas deste grupo, e o PL/pgSQL recusa acesso a um
  -- campo inexistente de um record ("record new has no field utente_id").
  -- Só se chega aqui depois de o catálogo confirmar que a coluna existe.
  execute 'select $1.utente_id, $1.clinica_id' into v_utente, v_clinica using new;

  if v_utente is null or v_clinica is null then
    return new;
  end if;

  select u.clinica_id into v_utente_clinica
    from public.utentes u
   where u.id = v_utente;

  if v_utente_clinica is distinct from v_clinica then
    raise exception
      'Incoerência multi-tenant: utente % pertence a outra clínica.', v_utente
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end $$;

do $$
declare
  t text;
  tabelas text[] := array[
    'episodios','diagnosticos','episodio_cif','agendamentos','atos_clinicos',
    'sessoes','medicoes','mfr_avaliacao_dor','mfr_movimento','mfr_avaliacao_funcao',
    'mfr_escala_aplicada','mfr_observacoes','planos','plano_objetivos',
    'criterios_alta','objetivo_progresso','requisicoes','prescricoes',
    'relatorios','media','hep_prescricoes'
  ];
begin
  foreach t in array tabelas loop
    execute format('drop trigger if exists t_%1$s_coerencia on public.%1$I;', t);
    execute format(
      'create trigger t_%1$s_coerencia before insert or update on public.%1$I
         for each row execute function clinia.validar_coerencia_clinica();', t);
  end loop;
end $$;

comment on function clinia.validar_coerencia_clinica() is
  'Impede registos clínicos que cruzem clínicas (isolamento multi-tenant real).';

-- ---------------------------------------------------------------------------
-- 6. Posição da sessão no episódio (numero_sessao automático)
-- ---------------------------------------------------------------------------
create or replace function clinia.numerar_sessao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.numero_sessao is null and new.episodio_id is not null then
    select count(*) + 1 into new.numero_sessao
      from public.sessoes s
     where s.episodio_id = new.episodio_id
       and s.data_sessao <= new.data_sessao;
  end if;
  return new;
end $$;

drop trigger if exists t_sessoes_numerar on public.sessoes;
create trigger t_sessoes_numerar
  before insert on public.sessoes
  for each row execute function clinia.numerar_sessao();

-- ---------------------------------------------------------------------------
-- 7. Indicadores de decisão clínica
-- ---------------------------------------------------------------------------

-- 7.1 Evolução das medições: primeira, última, melhor, variação e tendência.
--     Esta vista é a fonte do gráfico de evolução pedido no blueprint.
create or replace view public.vw_evolucao_medicoes as
with base as (
  select m.clinica_id,
         m.utente_id,
         m.episodio_id,
         m.codigo,
         coalesce(m.rotulo, m.codigo) as rotulo,
         m.unidade,
         m.melhor_direcao,
         m.medido_em,
         m.valor,
         m.momento,
         row_number() over (partition by m.utente_id, m.codigo, coalesce(m.episodio_id, m.utente_id)
                            order by m.medido_em) as n,
         count(*)   over (partition by m.utente_id, m.codigo, coalesce(m.episodio_id, m.utente_id)) as total
    from public.medicoes m
)
select b.clinica_id,
       b.utente_id,
       b.episodio_id,
       b.codigo,
       b.rotulo,
       b.unidade,
       b.melhor_direcao,
       b.total                                                        as numero_medicoes,
       (array_agg(b.valor order by b.medido_em))[1]                    as valor_inicial,
       (array_agg(b.valor order by b.medido_em desc))[1]               as valor_atual,
       case b.melhor_direcao
         when 'maior_melhor' then max(b.valor)
         when 'menor_melhor' then min(b.valor)
       end                                                            as valor_melhor,
       case b.melhor_direcao
         when 'maior_melhor' then (array_agg(b.valor order by b.medido_em desc))[1]
                                   - (array_agg(b.valor order by b.medido_em))[1]
         when 'menor_melhor' then (array_agg(b.valor order by b.medido_em))[1]
                                   - (array_agg(b.valor order by b.medido_em desc))[1]
       end                                                            as ganho,
       min(b.medido_em)                                               as primeira_medicao,
       max(b.medido_em)                                               as ultima_medicao
  from base b
 group by b.clinica_id, b.utente_id, b.episodio_id, b.codigo, b.rotulo,
          b.unidade, b.melhor_direcao, b.total;

comment on view public.vw_evolucao_medicoes is
  'Evolução por medição: inicial, atual, melhor e ganho na direção clínica correta.';

-- 7.2 Estado de objetivos do episódio, com aviso de estagnação.
--     A pergunta "estamos a chegar a algum lado?" respondida em dados.
create or replace view public.vw_objetivos_em_risco as
  select o.clinica_id,
         o.episodio_id,
         o.utente_id,
         o.id                as objetivo_id,
         o.descricao,
         o.estado,
         o.progresso_percentual,
         o.prazo,
         o.prioridade,
         (o.prazo is not null and o.prazo < current_date
          and o.estado = 'em_curso')                          as prazo_excedido,
         (o.progresso_percentual < 50
          and o.prazo is not null
          and o.prazo < current_date + interval '14 days')     as risco_estagnacao,
         (current_date - coalesce(
            (select max(p.data_registo) from public.objetivo_progresso p
              where p.objetivo_id = o.id), o.created_at::date)) as dias_sem_registo
    from public.plano_objetivos o
   where o.arquivado_em is null
     and o.estado = 'em_curso';

comment on view public.vw_objetivos_em_risco is
  'Objetivos por atingir com prazo excedido ou sem progresso registado.';

-- 7.3 Assiduidade: faltas repetidas são o primeiro sinal de abandono.
create or replace view public.vw_assiduidade_utente as
  select a.clinica_id,
         a.utente_id,
         a.episodio_id,
         count(*)                                                         as total_marcacoes,
         count(*) filter (where a.estado = 'realizado')                    as realizadas,
         count(*) filter (where a.estado = 'falta')                        as faltas,
         count(*) filter (where a.estado = 'desmarcado')                   as desmarcadas,
         count(*) filter (where a.estado = 'cancelado')                    as canceladas,
         round(100.0 * count(*) filter (where a.estado = 'realizado')
               / nullif(count(*) filter (where a.estado in ('realizado','falta')), 0), 1)
                                                                          as taxa_comparecimento,
         max(a.inicio) filter (where a.estado = 'realizado')               as ultima_sessao_realizada,
         min(a.inicio) filter (where a.estado = 'falta')                   as primeira_falta
    from public.agendamentos a
   group by a.clinica_id, a.utente_id, a.episodio_id;

comment on view public.vw_assiduidade_utente is
  'Assiduidade por episódio. Sinal precoce de abandono do tratamento.';

-- 7.4 Painel do episódio: tudo o que o clínico precisa de ver ao abrir a ficha,
--     num só pedido. Evita o "N+1 de ecrãs" que torna a app lenta no dia a dia.
create or replace view public.vw_episodio_resumo as
  select e.id                                    as episodio_id,
         e.clinica_id,
         e.utente_id,
         e.numero_episodio,
         e.especialidade,
         e.estado,
         e.motivo_principal,
         e.data_inicio,
         e.queixa_principal,
         e.expectativa_utente,
         e.profissional_principal_id,
         (select count(*) from public.atos_clinicos a
           where a.episodio_id = e.id and a.arquivado_em is null)  as numero_atos,
         (select count(*) from public.sessoes s
           where s.episodio_id = e.id)                             as numero_sessoes,
         (select max(s.data_sessao) from public.sessoes s
           where s.episodio_id = e.id)                             as ultima_sessao,
         (select count(*) from public.plano_objetivos o
           where o.episodio_id = e.id and o.arquivado_em is null)   as total_objetivos,
         (select count(*) from public.plano_objetivos o
           where o.episodio_id = e.id and o.estado = 'atingido')    as objetivos_atingidos,
         (select count(*) from public.diagnosticos d
           where d.episodio_id = e.id and d.tipo = 'medico'
             and d.arquivado_em is null)                           as diagnosticos_medicos,
         (select count(*) from public.diagnosticos d
           where d.episodio_id = e.id and d.tipo = 'funcional'
             and d.arquivado_em is null)                           as diagnosticos_funcionais,
         -- O CIF é partilhado: contamos os códigos ativos no episódio
         (select count(*) from public.episodio_cif ic
           where ic.episodio_id = e.id and ic.arquivado_em is null) as codigos_cif,
         (select count(*) from public.requisicoes r
           where r.episodio_id = e.id and r.estado in ('emitida','enviada'))  as requisicoes_pendentes,
         (select count(*) from public.requisicoes r
           where r.episodio_id = e.id and r.estado = 'resultado_recebido')    as resultados_recebidos
    from public.episodios e;

comment on view public.vw_episodio_resumo is
  'Painel do episódio num só pedido. Base do ecrã de abertura de ficha.';

-- 7.5 Utentes sem consentimento válido — controlo RGPD proativo.
create or replace view public.vw_utentes_sem_consentimento as
  select u.clinica_id,
         u.id            as utente_id,
         u.nome,
         u.numero_utente,
         u.created_at,
         not clinia.tem_consentimento(u.id, 'tratamento')     as falta_tratamento,
         not clinia.tem_consentimento(u.id, 'dados_pessoais') as falta_dados
    from public.utentes u
   where u.arquivado_em is null
     and (not clinia.tem_consentimento(u.id, 'tratamento')
          or not clinia.tem_consentimento(u.id, 'dados_pessoais'));

comment on view public.vw_utentes_sem_consentimento is
  'Controlo RGPD: utentes ativos sem consentimento de tratamento ou de dados.';


-- ----------------------------------------------------------------------------
-- 0012_endurecer_vistas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0012 — Endurecimento das vistas
--
-- Detalhe que passa despercebido e que anularia todo o RLS: em PostgreSQL, uma
-- vista é executada com os privilégios do seu DONO. Como o dono aqui é o papel
-- das migrações (que não tem RLS aplicado), consultar uma vista devolvia linhas
-- de TODAS as clínicas, mesmo com o RLS perfeito nas tabelas.
--
-- A correção é `security_invoker = true` (PostgreSQL 15+): a vista passa a
-- correr com os privilégios de quem consulta, e o RLS das tabelas base volta a
-- ser a autoridade. É a diferença entre ter RLS e ter RLS a funcionar.
-- ============================================================================

do $$
declare
  v text;
  vistas text[] := array[
    'vw_episodio_objetivos',
    'vw_evolucao_medicoes',
    'vw_objetivos_em_risco',
    'vw_assiduidade_utente',
    'vw_episodio_resumo',
    'vw_utentes_sem_consentimento',
    'vw_meu_contexto',
    'agenda'            -- vista de compatibilidade com o protótipo
  ];
begin
  foreach v in array vistas loop
    begin
      execute format('alter view public.%I set (security_invoker = true);', v);
    exception when others then
      -- Vista inexistente ou versão de PostgreSQL anterior à 15: avisa e segue.
      raise warning 'Não foi possível aplicar security_invoker à vista % (%): %',
        v, sqlstate, sqlerrm;
    end;
  end loop;
end $$;

-- Confirmação explícita: as vistas de leitura devem ter security_invoker.
do $$
declare
  v record;
  v_falhas text[] := '{}';
begin
  for v in
    select c.relname, coalesce(array_to_string(c.reloptions, ','), '') as opts
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
  loop
    if v.opts not like '%security_invoker=true%' then
      v_falhas := v_falhas || v.relname;
    end if;
  end loop;

  if array_length(v_falhas, 1) > 0 then
    raise warning
      'Vistas sem security_invoker (podem contornar o RLS): %',
      array_to_string(v_falhas, ', ');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Privilégios de leitura nas vistas (o RLS das tabelas base faz o resto).
-- ---------------------------------------------------------------------------
do $$
declare
  v text;
  vistas text[] := array[
    'vw_episodio_objetivos','vw_evolucao_medicoes','vw_objetivos_em_risco',
    'vw_assiduidade_utente','vw_episodio_resumo','vw_utentes_sem_consentimento',
    'vw_meu_contexto','agenda'
  ];
begin
  foreach v in array vistas loop
    begin
      execute format('grant select on public.%I to authenticated;', v);
    exception when others then null;
    end;
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- 0013b_produtos_e_modulos.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0013 — Produtos e módulos ativáveis
--
-- PORQUÊ ESTA MIGRAÇÃO
-- ============================================================================
-- A plataforma deixa de ser um produto único e passa a ser:
--
--     clinIA rehab  ·  reabilitação   →  módulo MFR, osteopatia, TO, fala
--     clinIA endoscopy · endoscopia   →  módulos gastro, ORL, pneumo, uro, gineco
--
-- Partilham o núcleo (utentes, agenda, episódios, motor de atos, escalas,
-- requisições, relatórios, auditoria). O que muda entre produtos e módulos é
-- QUAIS ATOS existem e QUE CAMPOS cada ato tem.
--
-- O motor de atos já foi desenhado para isto: `atos_clinicos` guarda o ato
-- genérico e o conteúdo específico vive em `dados jsonb`. O que faltava era a
-- peça que torna um módulo ATIVÁVEL — e é isso que aqui se acrescenta.
--
-- DISTINÇÃO IMPORTANTE (era fácil confundir)
--   · `especialidade`        — a especialidade DO PROFISSIONAL (enum já existente)
--   · `modulo`               — o módulo de software que a CLÍNICA tem ativo
-- São coisas diferentes: um ortopedista pode trabalhar num módulo de reabilitação,
-- e uma clínica de rehab pode ter o módulo MFR ativo sem ter nenhum fisiatra.
--
-- `mfr` já existia no enum `especialidade`, mas como especialidade de pessoas.
-- Passa agora a existir também como módulo.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Produtos
--
-- São dois, e são fixos: representam linhas de produto, não configuração de
-- cliente. Por isso é um enum e não uma tabela — acrescentar um produto é uma
-- decisão de negócio que passa por uma migração, e isso é desejável: obriga a
-- pensar antes de alargar a oferta.
--
-- `create type` não tem `if not exists` e, ao contrário de `create table`, não
-- pode ser repetido em silêncio: numa segunda execução dá
-- «type "produto" already exists». O bloco abaixo torna a migração repetível,
-- que é a promessa que o ficheiro de instalação faz a quem o cola no SQL Editor.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public' and t.typname = 'produto'
  ) then
    create type public.produto as enum ('rehab', 'endoscopy');
  end if;
end $$;

comment on type public.produto is
  'Linha de produto. rehab = reabilitação (MFR, osteopatia, TO, fala); endoscopy = endoscopia (gastro, ORL, pneumo, uro, gineco).';

alter table public.clinicas
  add column if not exists produto public.produto not null default 'rehab';

comment on column public.clinicas.produto is
  'Produto principal da clínica. Uma clínica pode ter módulos de ambos os produtos, mas esta coluna diz qual é a sua identidade e o que aparece por omissão.';

create index if not exists idx_clinicas_produto on public.clinicas (produto);


-- ---------------------------------------------------------------------------
-- 2. Catálogo de módulos
--
-- Cada módulo é um contrato: define os seus atos e os campos respetivos. Este
-- catálogo é o REGISTO — que módulos existem, a que produto pertencem, em que
-- versão de schema estão, e se estão prontos a ativar.
--
-- `disponivel` existe para se poder registar um módulo antes de ele estar
-- construído, sem o deixar ser ativado por engano. Um módulo planeado fica com
-- disponivel = false e não aparece na interface de ativação.
-- ---------------------------------------------------------------------------
create table if not exists public.modulos (
  codigo           text primary key,                      -- 'mfr', 'gastro', 'orl'...
  nome             text not null,
  produto          public.produto not null,
  descricao        text,
  versao_schema    text not null default '1.0',           -- versão do JSON Schema dos atos
  disponivel       boolean not null default false,        -- pronto a ativar?
  ordem            integer not null default 100,          -- ordem de apresentação
  icone            text,                                  -- nome do ícone na interface
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint modulos_codigo_formato check (codigo ~ '^[a-z][a-z0-9_]{1,30}$')
);

comment on table public.modulos is
  'Catálogo de módulos de especialidade. O núcleo é comum; cada módulo traz os seus atos, escalas e campos.';

drop trigger if exists t_modulos_updated_at on public.modulos;
create trigger t_modulos_updated_at
  before update on public.modulos
  for each row execute function clinia.set_updated_at();

create index if not exists idx_modulos_produto on public.modulos (produto, disponivel, ordem);


-- ---------------------------------------------------------------------------
-- 3. Módulos ativos por clínica
--
-- O coração desta migração. `clinica_id + modulo_codigo` diz que módulo uma
-- clínica tem ativo, desde quando e quem o ativou.
--
-- PORQUE É QUE A ATIVAÇÃO TEM DE ESTAR NO SERVIDOR
-- Esconder um botão na interface não impede um pedido direto à API. Como a
-- chave pública está no cliente, qualquer utilizador autenticado pode tentar
-- criar um ato de um módulo que a clínica não tem. A regra de negócio
-- ("esta clínica não tem o módulo gastro ativo") tem de ser imposta pela base
-- de dados — e é imposta pelo gatilho mais abaixo.
-- ---------------------------------------------------------------------------
create table if not exists public.clinica_modulos (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas(id) on delete cascade,
  modulo_codigo  text not null references public.modulos(codigo) on delete restrict,
  ativo          boolean not null default true,
  ativado_em     timestamptz not null default now(),
  ativado_por    uuid references public.perfis(id) on delete set null,
  desativado_em  timestamptz,
  notas          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint clinica_modulos_unico unique (clinica_id, modulo_codigo),
  constraint clinica_modulos_desativacao_coerente
    check ((ativo and desativado_em is null) or (not ativo))
);

comment on table public.clinica_modulos is
  'Que módulos cada clínica tem ativos. Imposto no servidor: um ato de um módulo inativo é recusado pela base de dados.';

drop trigger if exists t_clinica_modulos_updated_at on public.clinica_modulos;
create trigger t_clinica_modulos_updated_at
  before update on public.clinica_modulos
  for each row execute function clinia.set_updated_at();

create index if not exists idx_clinica_modulos_clinica on public.clinica_modulos (clinica_id) where ativo;


-- ---------------------------------------------------------------------------
-- 4. Ligar os atos clínicos ao módulo
--
-- `atos_clinicos` já tinha `especialidade`. Passa a ter também `modulo`, que é
-- a que decide se o ato é permitido. Mantém-se `especialidade` porque
-- continua a ser útil para filtrar e relatar, mas a autoridade passa a ser o
-- módulo.
--
-- A coluna começa nula e é preenchida por retrocompatibilidade: todos os atos
-- existentes pertencem ao módulo MFR, que é o único que existia.
-- ---------------------------------------------------------------------------
alter table public.atos_clinicos
  add column if not exists modulo text references public.modulos(codigo) on delete restrict;

comment on column public.atos_clinicos.modulo is
  'Módulo a que o ato pertence. Decide se o ato é permitido nesta clínica (ver clinia.validar_modulo_ativo).';

create index if not exists idx_atos_modulo on public.atos_clinicos (modulo);


-- ---------------------------------------------------------------------------
-- 5. Semear o catálogo
--
-- Os módulos do rehab estão construídos ou em construção; os da endoscopia
-- estão registados com disponivel = false, para o catálogo ser já a imagem
-- completa da oferta sem permitir ativar o que não existe.
-- ---------------------------------------------------------------------------
insert into public.modulos (codigo, nome, produto, descricao, versao_schema, disponivel, ordem, icone)
values
  ('mfr', 'Medicina Física e de Reabilitação', 'rehab',
   'Avaliação pelos três vetores (Dor · Movimento · Função), plano com critério de alta, sessões SOAP e medições de evolução. Serve fisiatria e fisioterapia.',
   '1.0', true, 10, 'atividade'),

  ('osteopatia', 'Osteopatia', 'rehab',
   'Mapa corporal, avaliação postural e notas flexíveis de terapia manual. Complementa o MFR quando o profissional tem formação em osteopatia.',
   '1.0', false, 20, 'corpo'),

  ('terapia_ocupacional', 'Terapia Ocupacional', 'rehab',
   'Avaliação de autonomia nas atividades de vida diária e adaptação do ambiente. Reutiliza o motor de escalas com instrumentos próprios.',
   '1.0', false, 30, 'casa'),

  ('terapia_da_fala', 'Terapia da Fala', 'rehab',
   'Avaliação e intervenção na comunicação e deglutição.',
   '1.0', false, 40, 'voz'),

  ('gastro', 'Gastroenterologia', 'endoscopy',
   'EDA, colonoscopia, CPRE e enteroscopia, com MST, Boston, Paris, Los Angeles, Forrest e indicadores de qualidade (ADR, intubação cecal).',
   '1.0', false, 110, 'endoscopia'),

  ('orl', 'Otorrinolaringologia', 'endoscopy',
   'Nasofaringolaringoscopia, otomicroscopia e sinuscopia, com RSI/RFS, Mallampati, Cormack-Lehane, GRBAS e Lund-Mackay.',
   '1.0', false, 120, 'orl'),

  ('pneumo', 'Pneumologia', 'endoscopy',
   'Broncoscopia e EBUS, com mapa de Boyden, estadiamento IASLC e registo de LBA e biópsias.',
   '1.0', false, 130, 'pulmao'),

  ('uro', 'Urologia', 'endoscopy',
   'Cistoscopia e URS, com mapa vesical e medição de lesões.',
   '1.0', false, 140, 'uro'),

  ('gineco', 'Ginecologia', 'endoscopy',
   'Histeroscopia e colposcopia, com classificação IFCPC/Swede e registo de pólipos e miomas.',
   '1.0', false, 150, 'gineco')
on conflict (codigo) do update
   set nome          = excluded.nome,
       produto       = excluded.produto,
       descricao     = excluded.descricao,
       versao_schema = excluded.versao_schema,
       disponivel    = excluded.disponivel,
       ordem         = excluded.ordem,
       icone         = excluded.icone;


-- ---------------------------------------------------------------------------
-- 6. Ativar o MFR em todas as clínicas existentes
--
-- Uma clínica que já usava o sistema estava a usar MFR, mesmo antes de os
-- módulos existirem. Desativá-la seria perder acesso a dados que já lá estão.
--
-- ATENÇÃO À ORDEM — foi aqui que a primeira versão falhou. O ficheiro de
-- instalação corre as migrações (Parte 1) ANTES do bootstrap (Parte 3), e é o
-- bootstrap que cria a clínica. Numa instalação de raiz, este `insert` não
-- encontrava clínica nenhuma e não ativava nada: o MFR ficava desligado e a
-- aplicação recusava todos os atos. Passava nos testes de schema porque estes
-- não verificavam a ativação.
--
-- A correção tem duas partes:
--   a) esta instrução, que trata das clínicas que já existam quando a migração
--      corre (o caso de uma base de dados já em uso);
--   b) o gatilho mais abaixo, que ativa o MFR em qualquer clínica criada
--      DEPOIS — incluindo a do bootstrap e as que vierem a ser criadas.
-- ---------------------------------------------------------------------------
insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo)
select c.id, 'mfr', true
  from public.clinicas c
on conflict (clinica_id, modulo_codigo) do nothing;

-- Retrocompatibilidade: os atos existentes são do módulo MFR.
update public.atos_clinicos
   set modulo = 'mfr'
 where modulo is null;


-- ---------------------------------------------------------------------------
-- 6b. Uma clínica nova nasce com o MFR ativo
--
-- Decisão de produto: o módulo MFR é a base da linha rehab e existe desde o
-- primeiro dia. Uma clínica sem nenhum módulo ativo não consegue registar nada
-- — seria uma armadilha para quem acabou de se registar. Nasce com o MFR, e o
-- administrador desativa-o se não o quiser.
--
-- O gatilho corre como `security definer` porque a clínica é criada durante o
-- bootstrap, antes de existir um utilizador com sessão; as políticas de RLS
-- bloqueariam a inserção.
-- ---------------------------------------------------------------------------
create or replace function clinia.ativar_mfr_em_clinica_nova()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_modulo text;
begin
  /* ---------------------------------------------------------------------------
     O MÓDULO ATIVADO POR OMISSÃO RESPEITA O PRODUTO DA CLÍNICA.
     ---------------------------------------------------------------------------
     A versão anterior ligava o MFR a TODAS as clínicas novas, sem olhar ao
     produto. Numa clínica de endoscopia isso punha o módulo de reabilitação
     ligado — e com ele as tabelas mfr_*, os ecrãs de avaliação pelos três
     vetores, sessões SOAP e o plano com critério de alta. Ou seja: misturava as
     duas linhas de produto exatamente no sítio onde elas deviam estar separadas.

     A intenção original do gatilho era outra e é boa — «nenhuma clínica nasce
     sem nenhum módulo ativo». Essa garantia mantém-se, mas passa a ser cumprida
     DENTRO do produto da clínica:

       · rehab      -> liga o MFR (o único módulo de rehab disponível)
       · endoscopy  -> liga o primeiro módulo de endoscopia disponível, quando
                       houver algum. Hoje não há nenhum (os cinco estão com
                       disponivel = false), e por isso a clínica nasce sem
                       módulos — o que é correto: não se liga o que não existe.

     Assim que a gastro passar a disponivel = true, uma clínica de endoscopia
     criada a partir daí fica logo com ela ligada, sem ninguém se lembrar de o
     fazer. A regra deixa de depender de memória. */
  select m.codigo into v_modulo
    from public.modulos m
   where m.produto = new.produto
     and m.disponivel
   order by m.ordem
   limit 1;

  if v_modulo is not null then
    insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo)
    values (new.id, v_modulo, true)
    on conflict (clinica_id, modulo_codigo) do nothing;
  end if;
  return new;
end $$;

comment on function clinia.ativar_mfr_em_clinica_nova() is
  'Ativa, numa clinica nova, o primeiro modulo DISPONIVEL do produto dessa clinica. Rehab -> MFR; endoscopy -> o primeiro modulo de endoscopia disponivel, quando existir. Garante que uma clinica nunca fica sem modulo ativo por esquecimento, sem nunca lhe ligar um modulo de outro produto.';

drop trigger if exists t_clinica_nova_ativa_mfr on public.clinicas;
create trigger t_clinica_nova_ativa_mfr
  after insert on public.clinicas
  for each row execute function clinia.ativar_mfr_em_clinica_nova();


-- ---------------------------------------------------------------------------
-- 7. Funções de apoio
-- ---------------------------------------------------------------------------

/* O módulo está ativo nesta clínica?
   `stable` porque só lê. `security definer` porque é chamada por gatilhos e por
   políticas, e precisa de ver a tabela de módulos independentemente do RLS do
   utilizador que a invoca — de outro modo um utilizador sem política de leitura
   sobre `clinica_modulos` veria "não ativo" e seria bloqueado por engano. */
create or replace function clinia.modulo_ativo(p_clinica_id uuid, p_modulo text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.clinica_modulos cm
     where cm.clinica_id = p_clinica_id
       and cm.modulo_codigo = p_modulo
       and cm.ativo
  );
$$;

comment on function clinia.modulo_ativo(uuid, text) is
  'Indica se um módulo está ativo numa clínica. Usada pelas políticas de RLS e pelos gatilhos de validação.';

/* Módulos ativos da clínica do utilizador atual. Serve a interface para saber
   o que mostrar, sem ter de fazer várias chamadas. */
create or replace function clinia.meus_modulos()
returns table (codigo text, nome text, produto public.produto, versao_schema text, icone text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.codigo, m.nome, m.produto, m.versao_schema, m.icone
    from public.clinica_modulos cm
    join public.modulos m on m.codigo = cm.modulo_codigo
   where cm.clinica_id = clinia.current_clinica_id()
     and cm.ativo
     and m.disponivel
   order by m.ordem;
$$;

comment on function clinia.meus_modulos() is
  'Módulos disponíveis e ativos na clínica do utilizador. A interface usa isto para saber que ecrãs e atos mostrar.';

grant execute on function clinia.modulo_ativo(uuid, text) to authenticated;
grant execute on function clinia.meus_modulos() to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Impor a regra no servidor
--
-- Este gatilho é o que transforma "escondido na interface" em "impossível".
-- Sem ele, um pedido direto à API com a chave pública criaria um ato de um
-- módulo que a clínica não tem.
--
-- Corre ANTES de inserir ou atualizar, e só quando o módulo está identificado.
-- A mensagem de erro é explícita de propósito: quem estiver a integrar tem de
-- perceber que não é uma falha genérica, é uma regra de negócio.
-- ---------------------------------------------------------------------------
create or replace function clinia.validar_modulo_ativo()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_modulo text;
  v_clinica uuid;
begin
  v_modulo := new.modulo;

  /* Sem módulo identificado não há nada a validar: é o caso dos atos antigos,
     anteriores a esta migração, e de atos de núcleo que não pertencem a nenhum
     módulo (por exemplo, uma anotação administrativa). */
  if v_modulo is null then
    return new;
  end if;

  v_clinica := new.clinica_id;

  if v_clinica is null then
    raise exception 'Ato sem clínica: não é possível validar o módulo.'
      using errcode = 'not_null_violation';
  end if;

  if not exists (select 1 from public.modulos m where m.codigo = v_modulo) then
    raise exception 'Módulo "%" não existe no catálogo.', v_modulo
      using errcode = 'foreign_key_violation',
            hint = 'Consulta public.modulos para ver os módulos registados.';
  end if;

  if not clinia.modulo_ativo(v_clinica, v_modulo) then
    raise exception 'O módulo "%" não está ativo nesta clínica.', v_modulo
      using errcode = 'insufficient_privilege',
            hint = 'Um administrador ativa o módulo em Administração → Módulos, antes de registar atos deste tipo.';
  end if;

  return new;
end $$;

comment on function clinia.validar_modulo_ativo() is
  'Recusa atos de módulos que a clínica não tem ativos. Impõe no servidor o que a interface apenas sugere.';

drop trigger if exists t_atos_modulo_ativo on public.atos_clinicos;
create trigger t_atos_modulo_ativo
  before insert or update of modulo, clinica_id on public.atos_clinicos
  for each row execute function clinia.validar_modulo_ativo();


-- ---------------------------------------------------------------------------
-- 9. Ativar um módulo: função com auditoria
--
-- A ativação passa por uma função em vez de um INSERT direto por duas razões:
-- registar quem ativou (a auditoria é requisito em software clínico) e validar
-- que o módulo está disponível antes de o ligar.
-- ---------------------------------------------------------------------------
create or replace function clinia.ativar_modulo(p_modulo text, p_ativo boolean default true)
returns public.clinica_modulos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid;
  v_disponivel boolean;
  v_registo public.clinica_modulos;
begin
  v_clinica := clinia.current_clinica_id();

  if v_clinica is null then
    raise exception 'Sem clínica associada ao utilizador.' using errcode = 'insufficient_privilege';
  end if;

  /* Só administrador e gestão mexem em módulos: é uma decisão de contrato com
     a clínica, não uma preferência de utilizador. */
  if not clinia.e_admin() then
    raise exception 'Só o administrador ou a gestão podem ativar ou desativar módulos.'
      using errcode = 'insufficient_privilege';
  end if;

  select m.disponivel into v_disponivel from public.modulos m where m.codigo = p_modulo;
  if v_disponivel is null then
    raise exception 'Módulo "%" não existe.', p_modulo using errcode = 'no_data_found';
  end if;
  if p_ativo and not v_disponivel then
    raise exception 'O módulo "%" ainda não está disponível nesta versão da plataforma.', p_modulo
      using errcode = 'feature_not_supported';
  end if;

  /* `ativado_em` é NOT NULL, e desativar tem de o manter: o registo de quando o
     módulo foi ligado pela primeira vez é informação de auditoria. A primeira
     versão passava NULL ao desativar e a operação era recusada pela base de
     dados — o teste apanhou-o. */
  insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo, ativado_por, ativado_em, desativado_em)
  values (v_clinica, p_modulo, p_ativo, auth.uid(), now(),
          case when p_ativo then null else now() end)
  on conflict (clinica_id, modulo_codigo) do update
     set ativo         = excluded.ativo,
         desativado_em = excluded.desativado_em,
         ativado_por   = case when excluded.ativo then auth.uid() else public.clinica_modulos.ativado_por end
  returning * into v_registo;

  return v_registo;
end $$;

comment on function clinia.ativar_modulo(text, boolean) is
  'Ativa ou desativa um módulo na clínica do utilizador. Regista quem o fez. Só administrador ou gestão.';

grant execute on function clinia.ativar_modulo(text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. Segurança das tabelas novas (RLS)
--
-- As tabelas desta migração são criadas DEPOIS da migração 0010, que é quem
-- aplica o RLS e os grants. Por isso têm de ser tratadas aqui, explicitamente.
-- ---------------------------------------------------------------------------
alter table public.modulos         enable row level security;
alter table public.clinica_modulos enable row level security;

grant select, insert, update, delete on public.modulos         to authenticated;
grant select, insert, update, delete on public.clinica_modulos to authenticated;
grant all on public.modulos         to service_role;
grant all on public.clinica_modulos to service_role;

/* CATÁLOGO DE MÓDULOS
   Leitura para qualquer utilizador autenticado: é a lista da oferta da
   plataforma, não contém dados de nenhuma clínica. Escrita apenas pelo
   service_role — o catálogo muda por migração, não pela aplicação. Repara que
   não existe política de INSERT/UPDATE/DELETE para `authenticated`: com RLS
   ativo e sem política, a operação é recusada. */
drop policy if exists modulos_select on public.modulos;
create policy modulos_select on public.modulos
  for select to authenticated
  using (true);

/* MÓDULOS ATIVOS POR CLÍNICA
   Cada clínica só vê os seus. A escrita passa pela função `clinia.ativar_modulo`,
   que é `security definer` e verifica o papel — por isso aqui a política de
   escrita é restrita ao administrador, como segunda barreira. */
drop policy if exists clinica_modulos_select on public.clinica_modulos;
create policy clinica_modulos_select on public.clinica_modulos
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id());

drop policy if exists clinica_modulos_write on public.clinica_modulos;
create policy clinica_modulos_write on public.clinica_modulos
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_admin())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_admin());


-- ---------------------------------------------------------------------------
-- 11. Auditoria das ativações
--
-- Ligar ou desligar um módulo muda o que a clínica pode registar. Fica no
-- registo de auditoria, como as restantes alterações com efeito clínico.
-- ---------------------------------------------------------------------------
drop trigger if exists t_clinica_modulos_auditoria on public.clinica_modulos;
create trigger t_clinica_modulos_auditoria
  after insert or update or delete on public.clinica_modulos
  for each row execute function clinia.auditar();


-- ----------------------------------------------------------------------------
-- 0014_faturacao_visibilidade.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0014 — Visibilidade por perfil e faturação (PT)
--
-- Ficheiro escrito DEPOIS da 0013 (produtos e módulos ativos). Não repete nada
-- do que lá está: usa `clinica_modulos` e `clinia.modulo_ativo()` como já
-- existem, e acrescenta as duas peças que faltavam:
--
--   A. VISIBILIDADE POR PERFIL, ao nível do ecrã — pedido direto do dono:
--      "atribuir visibilidade a cada função".
--   B. O MODELO DE DADOS DA FATURAÇÃO portuguesa, com as regras que a lei
--      impõe (numeração sem saltos, ATCUD, hash encadeado, imutabilidade,
--      IVA por linha com motivo de isenção obrigatório).
--
-- O que este ficheiro NÃO faz, de propósito:
--   · Não assina documentos. O Hash RSA-SHA256 exige a chave privada da
--     clínica, e a chave privada NÃO pode estar na base de dados em claro nem,
--     muito menos, no cliente. Guarda-se o resultado da assinatura e impõe-se
--     a CADEIA (cada documento tem de apontar para o hash do anterior da
--     mesma série). A assinatura vive numa função de servidor.
--   · Não emite o SAF-T (PT). O XML é gerado a partir destas tabelas.
--
-- Princípio que atravessa tudo: o que é obrigação legal vive na base de dados.
-- Uma regra de faturação que só exista na interface é uma regra que o cliente
-- contorna com um pedido HTTP — e a chave pública do Supabase vai no build.
-- ============================================================================

-- digest()/encode() são usados na impressão digital da cadeia de hashes.
create extension if not exists pgcrypto;

-- ============================================================================
-- A. VISIBILIDADE POR PERFIL, AO NÍVEL DO ECRÃ
--
-- A tentação é guardar a lista de ecrãs permitidos em perfis.preferencias
-- (jsonb) e esconder no frontend. Em dados de saúde (RGPD art. 9) isso é uma
-- falsa segurança: qualquer utilizador autenticado pode chamar o PostgREST
-- diretamente e ler o que a interface esconde.
--
-- Desenho: a decisão é DADO (por clínica, por perfil, por ecrã) e o RLS
-- pergunta-lhe. A interface lê a mesma tabela só para não mostrar o que o
-- servidor vai recusar.
--
-- Nota deliberada: `area` NÃO substitui `perfil_tipo`. O perfil diz o que a
-- PESSOA é (médico, receção); a área diz o que o ECRÃ revela. Um administrador
-- sem perfil clínico continua a não ler conteúdo clínico — é exatamente o que
-- o documento de referência pede ("notas clínicas partilhadas com o médico da
-- equipa mas não com um administrador sem perfil clínico").
-- ============================================================================

do $$ begin
  create type public.ecra_area as enum (
    'clinica',        -- revela conteúdo clínico: diagnóstico, notas, avaliações
    'agenda',         -- marcações e identificação do utente, sem conteúdo clínico
    'administrativa', -- utentes, contactos, consentimentos, documentos
    'faturacao',      -- atos praticados e valores. NÃO revela diagnóstico
    'gestao'          -- indicadores agregados
  );
exception when duplicate_object then null; end $$;

-- Catálogo de ecrãs. Global: é a lista de ecrãs que o produto tem.
create table if not exists public.ecras (
  id                uuid primary key default gen_random_uuid(),
  /* O código é a ROTA do ecrã no cliente — 'episodios', 'avaliacao', 'faturacao'.
   *
   * Tem de coincidir exatamente: a navegação pergunta ao servidor «posso ver o
   * ecrã `episodios`?», e a resposta é procurada por este código. Três ecrãs
   * estiveram aqui no singular enquanto as rotas eram plurais, e desapareceram
   * do menu sem um único erro. A migração 0022 corrige-os.

   * Ver `tools/testar_codigos_de_ecra.mjs`: compara esta lista com as rotas
   * registadas no cliente e falha quando divergem. */
  codigo            text not null unique,
  nome              text not null,
  grupo             text,                      -- agrupamento no menu lateral
  ordem             smallint not null default 100,
  area              public.ecra_area not null,
  -- Que módulo tem de estar ligado para o ecrã existir para a clínica.
  -- Referencia o catálogo da 0013: um ecrã de gastro não aparece a uma clínica
  -- que não tem o módulo gastro ativo.
  modulo_codigo     text references public.modulos(codigo) on delete set null,
  -- Perfis a quem o ecrã pode ser atribuído. Impede uma configuração absurda
  -- (dar faturação a um utente do portal).
  visivel_em        public.perfil_tipo[] not null default '{}',
  -- Ecrãs que não se desligam: sem eles não há processo clínico nem faturação
  -- legal. A coluna existe para a interface poder explicar porquê, em vez de
  -- mostrar uma caixa que não faz nada.
  obrigatorio       boolean not null default false,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists t_ecras_updated_at on public.ecras;
create trigger t_ecras_updated_at
  before update on public.ecras
  for each row execute function clinia.set_updated_at();

create index if not exists idx_ecras_area on public.ecras (area, ordem) where ativo;

comment on table public.ecras is
  'Catálogo global de ecrãs. A atribuição por clínica vive em perfil_visibilidade.';

-- Atribuição: (clínica, perfil, ecrã). Uma linha por combinação concedida.
--
-- Porque uma tabela de junção e não um array na tabela dos perfis: a decisão
-- tem de ser auditável ("quem tirou o ecrã de faturação à receção, e quando"),
-- e um array num jsonb não dá para auditar nem para indexar em RLS.
create table if not exists public.perfil_visibilidade (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete cascade,
  perfil            public.perfil_tipo not null,
  ecra_id           uuid not null references public.ecras(id) on delete cascade,
  visivel           boolean not null default true,
  -- Só leitura quando true: o ecrã abre mas não grava. Ex.: a gestão vê a
  -- faturação para conferir, sem poder emitir.
  apenas_leitura    boolean not null default false,
  atribuido_por     uuid references public.perfis(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint perfil_visibilidade_leitura_exige_visivel
    check (not apenas_leitura or visivel)
);

create unique index if not exists uq_perfil_visibilidade
  on public.perfil_visibilidade (clinica_id, perfil, ecra_id);
create index if not exists idx_perfil_visibilidade_clinica
  on public.perfil_visibilidade (clinica_id, perfil) where visivel;

drop trigger if exists t_perfil_visibilidade_updated_at on public.perfil_visibilidade;
create trigger t_perfil_visibilidade_updated_at
  before update on public.perfil_visibilidade
  for each row execute function clinia.set_updated_at();

comment on table public.perfil_visibilidade is
  'Quem vê que ecrã, por clínica. Fonte de verdade — a interface só a lê.';

-- Funções de contexto para o RLS. São ESTAS que as políticas usam: a política
-- nunca fala de nomes de ecrãs, senão passar a faturação por RLS obrigava a
-- reescrever políticas em vez de mudar uma linha numa tabela.
create or replace function clinia.ve_ecra(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = public, clinia
as $$
  select exists (
    select 1
      from public.perfil_visibilidade v
      join public.ecras e on e.id = v.ecra_id
     where v.clinica_id = clinia.current_clinica_id()
       and v.perfil = clinia.current_perfil()
       and v.visivel
       and e.codigo = p_codigo
       and e.ativo
  )
  -- O administrador não fica trancado fora da própria configuração.
  or clinia.e_admin();
$$;

create or replace function clinia.pode_escrever_ecra(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = public, clinia
as $$
  select exists (
    select 1
      from public.perfil_visibilidade v
      join public.ecras e on e.id = v.ecra_id
     where v.clinica_id = clinia.current_clinica_id()
       and v.perfil = clinia.current_perfil()
       and v.visivel
       and not v.apenas_leitura
       and e.codigo = p_codigo
       and e.ativo
  );
$$;

comment on function clinia.ve_ecra(text) is
  'RLS: o perfil autenticado vê este ecrã nesta clínica?';
comment on function clinia.pode_escrever_ecra(text) is
  'RLS: o perfil autenticado pode GRAVAR neste ecrã (não é só leitura)?';

-- ============================================================================
-- B. FATURAÇÃO
-- ============================================================================

-- ---------------------------------------------------------------------------
-- B.1 DADOS FISCAIS DA CLÍNICA
--
-- A fatura identifica QUEM emite. Num SaaS multi-tenant isso não é
-- necessariamente a clínica: há clínicas onde cada profissional fatura em nome
-- próprio. Por isso estes campos vivem em tabela própria, com a
-- responsabilidade fiscal explícita, e não espalhados em clinicas.configuracoes.
--
-- ATENÇÃO (decisão de produto, não técnica): uma fatura tem UM emitente. Se a
-- clínica agrega profissionais que faturam cada um por si, são séries
-- separadas, com NIF próprio. O modelo suporta-o porque tudo pende de
-- clinica_id + série.
-- ---------------------------------------------------------------------------
create table if not exists public.clinica_fiscal (
  id                    uuid primary key default gen_random_uuid(),
  clinica_id            uuid not null unique references public.clinicas(id) on delete cascade,

  nif                   text not null,          -- NIF do emitente (9 dígitos)
  nome_fiscal           text not null,          -- como sai na fatura
  morada                text not null,
  codigo_postal         text,
  localidade            text,
  pais                  text not null default 'PT',
  email_faturacao       text,
  telefone              text,

  -- Regime de IVA. Muda o CÓDIGO DE ISENÇÃO e é a confusão mais frequente:
  --   normal        -> liquida IVA às taxas em vigor
  --   isencao_art53 -> regime especial de isenção (volume de negócios)
  --   isento_art9   -> não liquida por natureza da operação (saúde). Caso típico do MFR
  regime_iva            text not null default 'isento_art9',
  -- Isenção ao abrigo do artigo 9.º, por tipo de ato. Deliberadamente texto: a
  -- redação da norma é da AT, não nossa, e citá-la erradamente na fatura é uma
  -- coima. O contabilista da clínica confirma o texto e o CÓDIGO.
  mencao_isencao_art9   text,

  -- Certificação: números que só existem DEPOIS de haver certificado.
  -- Nulos enquanto não houver. Um campo preenchido a fingir é uma afirmação
  -- falsa ao cliente — é isso que este desenho impossibilita.
  software_nome         text not null default 'clinIA',
  software_versao       text,
  certificado_numero    text,                   -- ex.: '1234/AT'
  certificado_validade  date,
  certificado_entidade  text,                   -- CEIIA, APCER, SGS, ...

  -- SAF-T (PT)
  saft_versao                  text not null default '1.04_01',
  saft_ultima_exportacao_ate   date,

  -- Chave privada: NUNCA aqui. Guarda-se apenas a impressão digital da chave
  -- pública ativa e o número de controlo (HashControl) que ela representa.
  -- O material criptográfico vive num cofre (KMS/Secrets), fora da base de dados.
  chave_publica_impressao text,
  chave_controlo_versao   text not null default '1',
  chave_criada_em         timestamptz,
  chave_rotativa          boolean not null default false,

  ativo                 boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint clinica_fiscal_nif_formato check (nif ~ '^[0-9]{9}$'),
  constraint clinica_fiscal_regime_valido
    check (regime_iva in ('normal','isencao_art53','isento_art9')),
  constraint clinica_fiscal_art9_tem_mencao
    check (regime_iva <> 'isento_art9' or mencao_isencao_art9 is not null),
  -- Um certificado sem número/validade/entidade é pior do que nenhum: aparece
  -- no SAF-T e no PDF.
  constraint clinica_fiscal_certificado_completo
    check (certificado_numero is null
           or (certificado_validade is not null and certificado_entidade is not null))
);

drop trigger if exists t_clinica_fiscal_updated_at on public.clinica_fiscal;
create trigger t_clinica_fiscal_updated_at
  before update on public.clinica_fiscal
  for each row execute function clinia.set_updated_at();

comment on table public.clinica_fiscal is
  'Dados do emitente de documentos fiscais. O certificado fica nulo ate existir certificado real.';
comment on column public.clinica_fiscal.chave_publica_impressao is
  'Impressao digital da chave publica ativa. A chave privada vive num cofre, nunca na base de dados.';

-- ---------------------------------------------------------------------------
-- B.2 TABELA DE ATOS FATURÁVEIS E PREÇOS
--
-- Faltava a ponte entre o que se faz clinicamente e o que se cobra. O ato
-- clínico (atos_clinicos) diz o que foi feito; o item faturavel diz o que isso
-- vale. Manter os dois separados é o que permite renegociar preços sem tocar em
-- registos clínicos — e faturar o mesmo ato a preços diferentes conforme o
-- pagador.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.pagador_tipo as enum (
    'particular',
    'seguradora',
    'adse',
    'sns',
    'empresa',
    'acidente_trabalho',
    'outro'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.itens_faturaveis (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid references public.clinicas(id) on delete cascade,   -- null = catálogo global
  codigo            text not null,
  designacao        text not null,
  descricao         text,
  -- Ligação ao clínico, sem o obrigar: um item pode ser material (joelheira)
  -- que não corresponde a nenhum tipo de ato.
  ato_tipo          public.ato_tipo,
  especialidade     public.especialidade,

  -- Preço de tabela (particular). O preço por convenção vive em precos_convencao.
  preco             numeric(12,2) not null default 0,
  unidade           text not null default 'sessao',   -- sessao | consulta | unidade | hora

  -- IVA por item. A taxa efetiva de cada linha é CONGELADA na emissão: mudar a
  -- taxa aqui amanhã não pode reescrever uma fatura de ontem.
  taxa_iva          smallint not null default 0,      -- pontos percentuais (0, 6, 13, 23)
  codigo_isencao    text,                             -- código da tabela oficial da AT (ex.: 'M07')
  mencao_isencao    text,

  requer_prescritor boolean not null default false,
  ativo             boolean not null default true,
  arquivado_em      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint itens_faturaveis_codigo_nao_vazio check (length(btrim(codigo)) > 0),
  constraint itens_faturaveis_designacao_nao_vazia check (length(btrim(designacao)) > 0),
  constraint itens_faturaveis_preco_nao_negativo check (preco >= 0),
  constraint itens_faturaveis_taxa_valida check (taxa_iva between 0 and 100),
  -- Taxa zero OBRIGA a motivo de isenção: é a regra que o validador da AT
  -- recusa quando falta, e a razão pela qual este check existe aqui e não na app.
  constraint itens_faturaveis_isencao_obrigatoria
    check (taxa_iva <> 0 or (codigo_isencao is not null and mencao_isencao is not null))
);

create unique index if not exists uq_itens_faturaveis_global
  on public.itens_faturaveis (codigo) where clinica_id is null;
create unique index if not exists uq_itens_faturaveis_clinica
  on public.itens_faturaveis (clinica_id, codigo) where clinica_id is not null;
create index if not exists idx_itens_faturaveis_ativo
  on public.itens_faturaveis (clinica_id, ativo) where arquivado_em is null;

drop trigger if exists t_itens_faturaveis_updated_at on public.itens_faturaveis;
create trigger t_itens_faturaveis_updated_at
  before update on public.itens_faturaveis
  for each row execute function clinia.set_updated_at();

comment on table public.itens_faturaveis is
  'Tabela de atos e produtos faturaveis. Preco de tabela; convencoes em precos_convencao.';

create table if not exists public.precos_convencao (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete cascade,
  item_id           uuid not null references public.itens_faturaveis(id) on delete cascade,
  pagador           public.pagador_tipo not null,
  seguradora        text,                     -- quando pagador = seguradora/empresa
  codigo_convencao  text,                     -- código exigido pela entidade pagadora
  preco             numeric(12,2) not null,
  -- Regra de comparticipação: o que a entidade paga e o que fica para o utente.
  -- Percentagens e não valores, para sobreviver a revisões de tabela.
  percentagem_entidade numeric(5,2),
  carencia_dias     integer,
  requer_autorizacao boolean not null default false,
  valido_de         date not null default current_date,
  valido_ate        date,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint precos_convencao_preco_nao_negativo check (preco >= 0),
  constraint precos_convencao_percentagem_valida
    check (percentagem_entidade is null or percentagem_entidade between 0 and 100),
  constraint precos_convencao_datas_coerentes
    check (valido_ate is null or valido_ate >= valido_de)
);

-- Um preço vigente por (clínica, item, pagador, seguradora). As versões
-- anteriores ficam com ativo=false e datas fechadas: o histórico de preços
-- explica faturas antigas.
create unique index if not exists uq_precos_convencao_vigente
  on public.precos_convencao (clinica_id, item_id, pagador, coalesce(seguradora, ''))
  where ativo;

drop trigger if exists t_precos_convencao_updated_at on public.precos_convencao;
create trigger t_precos_convencao_updated_at
  before update on public.precos_convencao
  for each row execute function clinia.set_updated_at();

comment on table public.precos_convencao is
  'Preco por pagador (seguradora, ADSE, SNS, empresa). O particular usa itens_faturaveis.preco.';

-- ---------------------------------------------------------------------------
-- B.3 SÉRIES DE DOCUMENTOS FISCAIS
--
-- A AT exige séries registadas e sem saltos. Consequência de desenho: o número
-- NÃO pode vir de uma sequence do PostgreSQL — uma sequence não recua quando a
-- transação falha, e deixa buracos. O contador é uma COLUNA, lida e
-- incrementada na mesma transação com lock de linha.
--
-- O número é POR ANO CIVIL ('FTR 2026/15'); o contador reinicia a 1 de janeiro,
-- pelo que a chave é (série, ano).
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.documento_tipo as enum (
    'fatura',                 -- FT
    'fatura_recibo',          -- FR: fatura com pagamento imediato
    'recibo',                 -- RC: recibo de fatura já emitida
    'nota_credito',           -- NC: anulação/devolução. NUNCA se edita a fatura
    'nota_debito',            -- ND
    'orcamento',              -- OR: não é documento fiscal, mas numera-se
    'recibo_verde',
    'outro'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.series_documentos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,

  tipo              public.documento_tipo not null,
  -- Código da série, sem espaços. É o cSerie do ATCUD e entra no Hash, portanto
  -- não pode mudar depois de haver documentos emitidos.
  codigo            text not null,            -- 'FTR', 'NC', 'FR2026'
  designacao        text not null,
  ano               smallint not null default extract(year from current_date),

  -- Registo da série na AT. A comunicação é obrigação DO CONTRIBUINTE, não do
  -- software: o software guarda o código atribuído e mostra-o.
  registo_at_valido boolean not null default false,
  registo_at_codigo text,                     -- código de validação devolvido pela AT

  -- Contador e último hash. Ambos têm de ser lidos e escritos na MESMA
  -- transação do documento (select ... for update).
  ultimo_numero     integer not null default 0,
  ultimo_hash       text,
  -- Referência informativa ao último documento. SEM chave estrangeira de
  -- propósito: é preenchida pelo gatilho de emissão ANTES de a linha do
  -- documento existir (o gatilho corre em BEFORE INSERT). A ligação com valor
  -- legal é `ultimo_hash`.
  ultimo_documento_id uuid,

  -- Chave de assinatura desta série. Se a chave da clínica girar, os documentos
  -- antigos continuam a validar-se com a chave antiga: por isso o número de
  -- controlo é da SÉRIE, não só da clínica.
  chave_controlo    text not null default '1',

  ativa             boolean not null default true,
  data_inicio       date not null default current_date,
  data_fim          date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint series_codigo_formato check (codigo ~ '^[A-Z0-9]{1,20}$'),
  constraint series_ano_plausivel check (ano between 2000 and 2100),
  constraint series_ultimo_numero_nao_negativo check (ultimo_numero >= 0),
  constraint series_datas_coerentes check (data_fim is null or data_fim >= data_inicio)
);

create unique index if not exists uq_series_clinica_codigo_ano
  on public.series_documentos (clinica_id, tipo, codigo, ano);
create index if not exists idx_series_ativas on public.series_documentos (clinica_id) where ativa;

drop trigger if exists t_series_documentos_updated_at on public.series_documentos;
create trigger t_series_documentos_updated_at
  before update on public.series_documentos
  for each row execute function clinia.set_updated_at();

comment on table public.series_documentos is
  'Serie documental com contador por ano. O numero sai daqui, nao de uma sequence (que deixa buracos).';
comment on column public.series_documentos.ultimo_hash is
  'Hash do ultimo documento da serie. Fecha a cadeia: o documento seguinte assina sobre este valor.';

-- ---------------------------------------------------------------------------
-- B.4 DOCUMENTOS FISCAIS
--
-- Regras que este desenho impõe:
--   · número sequencial por série, sem saltos     -> contador na série + unique
--   · ATCUD = cEmp + cSerie + nDoc                -> calculado, nunca escrito à mão
--   · hash encadeado                              -> coluna + avanço da série
--   · imutabilidade                               -> append-only por gatilho e por GRANT
--   · nada se apaga, anula-se por nota de crédito -> estado + documento_origem_id
--   · IVA por linha com motivo de isenção         -> linhas_documento
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.documento_estado as enum (
    'emitido',      -- final. Imutável a partir daqui.
    'anulado',      -- anulado por nota de crédito; aparece no SAF-T com estado A
    'liquidado',    -- fatura já paga; muda só por recibos
    'rascunho'      -- pré-visualização. Sem número, sem hash, FORA da cadeia legal.
  );
exception when duplicate_object then null; end $$;

create table if not exists public.documentos_fiscais (
  id                    uuid primary key default gen_random_uuid(),
  clinica_id            uuid not null references public.clinicas(id) on delete restrict,
  serie_id              uuid not null references public.series_documentos(id) on delete restrict,

  tipo                  public.documento_tipo not null,
  estado                public.documento_estado not null default 'rascunho',

  -- Numeração. Nula em rascunho: um rascunho NÃO consome número, senão o
  -- rascunho abandonado criava um salto na série — exatamente o que a AT verifica.
  ano                   smallint,
  numero                integer,
  -- Denormalizado da série: o ATCUD e o Hash têm de usar o código exato do
  -- momento da emissão, mesmo que a série seja renomeada mais tarde.
  serie_codigo          text,
  data_emissao          date,
  data_vencimento       date,

  -- Identificação do emitente NO MOMENTO da emissão: se a clínica mudar de nome
  -- ou de NIF, as faturas antigas continuam a dizer a verdade que diziam.
  emitente_nif          text,
  emitente_nome         text,
  emitente_morada       text,

  -- Adquirente. NIF nulo = consumidor final (permitido, mas obriga a mais
  -- cuidado com o SAF-T: o nó Customer exige identificação).
  adquirente_utente_id  uuid references public.utentes(id) on delete set null,
  adquirente_nome       text not null,
  adquirente_nif        text,
  adquirente_morada     text,
  adquirente_email      text,

  -- Quem paga, quando não é o utente
  pagador               public.pagador_tipo not null default 'particular',
  seguradora            text,
  numero_apolice        text,
  guia_autorizacao      text,                  -- nº de autorização prévia da seguradora/ADSE
  entidade_pagadora     text,

  -- Totais. numeric(12,2) e não float: dinheiro não se soma em vírgula
  -- flutuante, e a AT compara valores ao cêntimo.
  total_iliquido        numeric(12,2) not null default 0,
  total_iva             numeric(12,2) not null default 0,
  total_descontos       numeric(12,2) not null default 0,
  total_documento       numeric(12,2) not null default 0,
  -- Repartição por taxa, para o resumo de IVA. Ex.: {"23":{"base":0,"iva":0},"0":{...}}
  resumo_iva            jsonb not null default '{}'::jsonb,

  moeda                 text not null default 'EUR',
  observacoes           text,
  -- Menção legal que sai impressa. Obrigatória quando há linha a taxa 0.
  mencao_isencao        text,

  -- A "santíssima trindade": ATCUD, Hash, QR.
  atcud                 text,
  hash                  text,
  hash_controlo         text,
  -- Impressão digital exata dos dados que entraram na assinatura. Permite
  -- auditar o que foi assinado sem reconstruir a fórmula a partir dos totais.
  string_assinada       text,
  qrcode_url            text,

  -- Notas de crédito e débito
  documento_origem_id   uuid references public.documentos_fiscais(id) on delete restrict,
  motivo_anulacao       text,

  -- Ligação ao clínico: o que foi feito é o que se fatura
  episodio_id           uuid references public.episodios(id) on delete set null,
  utente_id             uuid references public.utentes(id) on delete set null,

  -- Ligação opcional a um pagamento (fatura-recibo)
  pago_em               timestamptz,
  pago_valor            numeric(12,2),

  -- Documento emitido no Storage (PDF com QR e ATCUD)
  documento_url         text,
  documento_hash_ficheiro text,

  emitido_por           uuid references public.perfis(id) on delete set null,
  emitido_em            timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid references public.perfis(id) on delete set null,

  -- Uma fatura emitida tem de estar completa. É a tradução, em linguagem de
  -- base de dados, de "não sai meia fatura".
  constraint documentos_emitido_completo
    check (
      estado = 'rascunho'
      or (numero is not null and ano is not null and serie_codigo is not null
          and data_emissao is not null and atcud is not null and hash is not null
          and emitente_nif is not null and emitido_em is not null)
    ),
  constraint documentos_rascunho_sem_numero
    check (estado <> 'rascunho' or (numero is null and hash is null and atcud is null)),
  constraint documentos_totais_nao_negativos
    check (total_iliquido >= 0 and total_iva >= 0 and total_documento >= 0),
  constraint documentos_moeda_valida check (moeda in ('EUR','USD','BRL','GBP')),
  -- Nota de crédito sem documento original é um crédito sem contrapartida.
  constraint documentos_nota_credito_tem_origem
    check (tipo <> 'nota_credito'
           or (documento_origem_id is not null and motivo_anulacao is not null)),
  -- Anulado exige motivo: o SAF-T tem de o declarar.
  constraint documentos_anulado_tem_motivo
    check (estado <> 'anulado'
           or (motivo_anulacao is not null and length(btrim(motivo_anulacao)) > 0)),
  constraint documentos_pagamento_coerente
    check ((pago_em is null) = (pago_valor is null))
);

create unique index if not exists uq_documentos_serie_ano_numero
  on public.documentos_fiscais (serie_id, ano, numero)
  where numero is not null;

/* Um documento só pode ser origem de UMA nota de crédito: sem isto, o mesmo
   erro podia ser creditado duas vezes e a receita desaparecia em silêncio. */
create unique index if not exists uq_documentos_uma_nota_credito
  on public.documentos_fiscais (documento_origem_id)
  where tipo = 'nota_credito' and estado <> 'anulado';

create index if not exists idx_documentos_clinica_data
  on public.documentos_fiscais (clinica_id, data_emissao desc);
create index if not exists idx_documentos_utente
  on public.documentos_fiscais (utente_id, data_emissao desc);
create index if not exists idx_documentos_pendentes
  on public.documentos_fiscais (clinica_id) where estado = 'emitido';

comment on table public.documentos_fiscais is
  'Documentos fiscais. Append-only: nao se edita nem se apaga; anula-se por nota de credito.';
comment on column public.documentos_fiscais.string_assinada is
  'Exatamente a string concatenada que foi assinada, para auditoria da assinatura.';

-- ---------------------------------------------------------------------------
-- B.5 LINHAS DE DOCUMENTO
--
-- IVA POR LINHA, com motivo de isenção por linha: é assim que a AT o exige e é
-- o que permite ter na mesma fatura uma consulta isenta (art. 9.º) e uma venda
-- de material à taxa normal.
-- ---------------------------------------------------------------------------
create table if not exists public.linhas_documento (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  documento_id      uuid not null references public.documentos_fiscais(id) on delete restrict,
  ordem             smallint not null default 1,

  item_id           uuid references public.itens_faturaveis(id) on delete set null,
  -- Cópia no momento da emissão: a tabela de preços pode mudar, a fatura não.
  codigo            text not null,
  descricao         text not null,

  quantidade        numeric(12,3) not null default 1,
  unidade           text not null default 'sessao',
  preco_unitario    numeric(12,2) not null,
  desconto_percentagem numeric(5,2) not null default 0,
  desconto_valor    numeric(12,2) not null default 0,

  -- IVA
  taxa_iva          smallint not null default 0,
  codigo_isencao    text,
  mencao_isencao    text,
  base_incidencia   numeric(12,2) not null default 0,
  valor_iva         numeric(12,2) not null default 0,
  total_linha       numeric(12,2) not null default 0,

  -- Ligação clínica: qual ato gerou esta linha. É o que responde a "porque é
  -- que esta sessão foi faturada?" numa auditoria ou numa reclamação.
  ato_id            uuid references public.atos_clinicos(id) on delete set null,
  profissional_id   uuid references public.profissionais(id) on delete set null,
  data_prestacao    date,

  created_at        timestamptz not null default now(),

  constraint linhas_documento_ordem_unica unique (documento_id, ordem),
  constraint linhas_documento_descricao_nao_vazia check (length(btrim(descricao)) > 0),
  constraint linhas_documento_quantidade_positiva check (quantidade > 0),
  constraint linhas_documento_preco_nao_negativo check (preco_unitario >= 0),
  constraint linhas_documento_taxa_valida check (taxa_iva between 0 and 100),
  constraint linhas_documento_descontos_validos
    check (desconto_percentagem between 0 and 100 and desconto_valor >= 0),
  -- A regra que o validador da AT recusa quando falta.
  constraint linhas_documento_isencao_obrigatoria
    check (taxa_iva <> 0 or (codigo_isencao is not null and mencao_isencao is not null)),
  -- Arredondamento ao cêntimo, feito onde os dados entram.
  constraint linhas_documento_valor_iva_arredondado
    check (valor_iva = round(valor_iva, 2)),
  constraint linhas_documento_base_arredondada
    check (base_incidencia = round(base_incidencia, 2))
);

create index if not exists idx_linhas_documento_doc on public.linhas_documento (documento_id, ordem);
create index if not exists idx_linhas_documento_ato on public.linhas_documento (ato_id);
create index if not exists idx_linhas_documento_item on public.linhas_documento (clinica_id, item_id);

comment on table public.linhas_documento is
  'Linhas com IVA e motivo de isencao POR LINHA. A mesma fatura pode ter isento e taxa normal.';

-- ---------------------------------------------------------------------------
-- B.6 PAGAMENTOS
--
-- Sem isto, a faturação fica cega: emite-se e não se sabe o que entrou. E o
-- dinheiro que não é conciliado é o primeiro sintoma de um serviço mal faturado.
-- ---------------------------------------------------------------------------
create table if not exists public.pagamentos (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  documento_id      uuid references public.documentos_fiscais(id) on delete restrict,
  utente_id         uuid references public.utentes(id) on delete set null,

  data_pagamento    date not null default current_date,
  valor             numeric(12,2) not null,
  metodo            text not null default 'numerario',
    -- numerario | multibanco | transferencia | mbway | cheque | seguro | adse | sns | outro
  referencia        text,
  -- Meio de pagamento de terceiro (seguradora): quem pagou e com que autorização
  entidade          text,
  observacoes       text,

  recebido_por      uuid references public.perfis(id) on delete set null,
  created_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  constraint pagamentos_valor_positivo check (valor > 0),
  constraint pagamentos_metodo_valido
    check (metodo in ('numerario','multibanco','transferencia','mbway','cheque',
                      'seguro','adse','sns','outro'))
);

create index if not exists idx_pagamentos_documento on public.pagamentos (documento_id);
create index if not exists idx_pagamentos_data      on public.pagamentos (clinica_id, data_pagamento desc);
create index if not exists idx_pagamentos_utente    on public.pagamentos (utente_id, data_pagamento desc);

comment on table public.pagamentos is
  'Pagamentos. Sem isto a faturacao fica cega: emite-se e nao se sabe o que entrou.';

-- ---------------------------------------------------------------------------
-- B.7 A CADEIA DE HASHES
--
-- É esta função que transforma uma tabela de faturas numa cadeia inalterável.
-- O gatilho NÃO calcula a assinatura (não tem a chave privada): VERIFICA a
-- coerência e AVANÇA a série.
--
--   · o documento foi numerado sequencialmente a partir do contador da série;
--   · a série avança o contador e guarda o hash que acabou de emitir;
--   · nenhum documento entra com número antigo (isso reescreveria história);
--   · o ATCUD corresponde a cEmp + cSerie + nDoc;
--   · um documento emitido sem hash é recusado — sem assinatura não tem valor
--     probatório, e entrava na cadeia a fingir que estava assinado.
--
-- A assinatura RSA em si é feita no servidor, com a chave no cofre, e chega
-- aqui já calculada (`hash`), com a string assinada ao lado para auditoria.
-- ---------------------------------------------------------------------------
create or replace function clinia.emitir_documento_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public, clinia, extensions
as $$
declare
  v_serie      public.series_documentos%rowtype;
  v_nif        text;
  v_esperado   integer;
  v_ultimo     integer;
begin
  -- Rascunho: fora da cadeia legal, sem número, sem ATCUD e sem consumir número
  -- da série. (O hash é exigido à parte, pela migração 0015, porque o documento
  -- já pode ser assinado antes de ser numerado.)
  if new.estado = 'rascunho' then
    return new;
  end if;

  -- Lock de linha na série. É isto que serializa a emissão: duas emissões
  -- simultâneas não podem ler o mesmo ultimo_numero. Sem o lock, a cadeia
  -- parte-se em silêncio e só se descobre na auditoria da AT.
  select * into v_serie
    from public.series_documentos s
   where s.id = new.serie_id
   for update;

  if v_serie.id is null then
    raise exception 'Série de documentos inexistente.' using errcode = 'foreign_key_violation';
  end if;

  if not v_serie.ativa then
    raise exception 'A série % está fechada e não emite documentos novos.', v_serie.codigo
      using errcode = 'check_violation';
  end if;

  -- Documento já numerado (importação de histórico): valida a coerência sem
  -- reescrever o contador para trás. Nunca se "recupera" um número antigo.
  if new.numero is not null then
    if new.ano <> v_serie.ano then
      raise exception 'Documento de % não pode entrar na série de %.', new.ano, v_serie.ano
        using errcode = 'check_violation';
    end if;
    if new.numero > v_serie.ultimo_numero then
      raise exception 'Documento % excede o contador da série (%). Importação fora de ordem?',
        new.numero, v_serie.ultimo_numero using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- Numeração: sem buracos, o próximo é sempre último + 1.
  v_ultimo   := coalesce(v_serie.ultimo_numero, 0);
  v_esperado := v_ultimo + 1;

  new.ano           := v_serie.ano;
  new.serie_codigo  := v_serie.codigo;
  new.numero        := v_esperado;
  new.data_emissao  := coalesce(new.data_emissao, current_date);
  new.emitido_em    := coalesce(new.emitido_em, now());
  new.hash_controlo := coalesce(new.hash_controlo, v_serie.chave_controlo);

  -- Identificação do emitente, congelada a partir da configuração fiscal.
  select cf.nif into v_nif from public.clinica_fiscal cf where cf.clinica_id = new.clinica_id;

  if new.emitente_nif is null then
    if v_nif is null then
      raise exception 'A clínica não tem dados fiscais configurados: não pode emitir documentos.'
        using errcode = 'check_violation',
              hint = 'Preenche os dados fiscais (NIF, nome, morada) antes de faturar.';
    end if;
    new.emitente_nif := v_nif;
  end if;

  -- ATCUD = cEmp + cSerie + nDoc. Derivado, nunca escrito à mão.
  new.atcud := new.emitente_nif || new.serie_codigo || new.numero::text;

  if new.hash is null then
    raise exception
      'Documento sem Hash: a assinatura tem de ser feita no servidor (chave privada no cofre).'
      using errcode = 'not_null_violation',
            hint = 'A emissão passa pela função de servidor, que assina e só depois grava.';
  end if;

  -- Duas faturas não podem partilhar a mesma assinatura: seria a prova de que
  -- um hash foi copiado em vez de calculado.
  if v_serie.ultimo_hash is not null and new.hash = v_serie.ultimo_hash then
    raise exception 'Hash repetido na série %: dois documentos não podem ter a mesma assinatura.',
      v_serie.codigo using errcode = 'unique_violation';
  end if;

  -- Avança a série. `ultimo_hash` fica com o hash DESTE documento: é o
  -- "documento anterior" do próximo, e é o que fecha a cadeia.
  update public.series_documentos
     set ultimo_numero = v_esperado,
         ultimo_hash = new.hash,
         ultimo_documento_id = new.id
   where id = v_serie.id;

  -- QR Code: URL de validação na AT com os parâmetros oficiais
  -- (c = NIF, i = número do documento, d = data, v = valor, q = hash).
  new.qrcode_url := 'https://faturas.portaldasfinancas.gov.pt/faturas/?c=' || new.emitente_nif ||
                    '&i=' || replace(new.serie_codigo || ' ' || new.ano::text || '/' || new.numero::text, ' ', '%20') ||
                    '&d=' || to_char(new.data_emissao, 'YYYYMMDD') ||
                    '&v=' || to_char(new.total_documento, 'FM999999990.00') ||
                    '&q=' || new.hash;

  return new;
end $$;

comment on function clinia.emitir_documento_fiscal() is
  'Numera a serie, calcula ATCUD e QR e avanca a cadeia. Exige hash pre-calculado no servidor.';

drop trigger if exists t_documentos_emitir on public.documentos_fiscais;
create trigger t_documentos_emitir
  before insert on public.documentos_fiscais
  for each row execute function clinia.emitir_documento_fiscal();

-- ---------------------------------------------------------------------------
-- B.8 IMUTABILIDADE
--
-- Três camadas, porque uma só não chega:
--   a) gatilho: recusa UPDATE/DELETE de documentos não-rascunho, com uma lista
--      curta de campos que PODEM mudar (pagamento, estado, ficheiro). Tudo o
--      resto — valores, datas, NIF, linhas — é intocável.
--   b) linhas: uma linha de documento emitido não se altera nem se apaga.
--   c) GRANT: o papel `authenticated` perde UPDATE e DELETE. É a camada que
--      protege mesmo contra um cliente manipulado, porque não depende de
--      nenhum gatilho correr.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_documento_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_permitidos text[] := array[
    'estado','motivo_anulacao','pago_em','pago_valor',
    'documento_url','documento_hash_ficheiro','updated_at'
  ];
  v_campo text;
begin
  if tg_op = 'DELETE' then
    raise exception
      'Documentos fiscais não se apagam (%). Anula-se com uma nota de crédito.', old.numero
      using errcode = 'check_violation',
            hint = 'Emite uma nota de crédito com o motivo da anulação.';
  end if;

  -- Rascunho é livre: ainda não é documento.
  if old.estado = 'rascunho' and new.estado = 'rascunho' then
    return new;
  end if;

  for v_campo in
    select key from jsonb_each(to_jsonb(new)) n
     where n.value is distinct from (to_jsonb(old) -> n.key)
  loop
    if not (v_campo = any (v_permitidos)) then
      raise exception
        'Documento fiscal emitido não pode ser alterado (campo "%"). Emite uma nota de crédito.',
        v_campo using errcode = 'check_violation';
    end if;
  end loop;

  -- Uma nota de crédito por documento original (o índice único parcial cobre o
  -- caso das já existentes; isto cobre a corrida).
  if new.estado = 'anulado' and old.estado <> 'anulado' then
    if exists (
      select 1 from public.documentos_fiscais d
       where d.documento_origem_id = old.id
         and d.tipo = 'nota_credito'
         and d.estado <> 'rascunho'
    ) then
      raise exception 'O documento % já tem uma nota de crédito emitida.', old.numero
        using errcode = 'unique_violation';
    end if;
  end if;

  return new;
end $$;

comment on function clinia.proteger_documento_fiscal() is
  'Impede edicao e remocao de documentos fiscais emitidos. Anulacao so por nota de credito.';

drop trigger if exists t_documentos_proteger on public.documentos_fiscais;
create trigger t_documentos_proteger
  before update or delete on public.documentos_fiscais
  for each row execute function clinia.proteger_documento_fiscal();

create or replace function clinia.proteger_linha_documento()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
declare
  v_estado public.documento_estado;
begin
  select d.estado into v_estado
    from public.documentos_fiscais d
   where d.id = coalesce(new.documento_id, old.documento_id);

  if v_estado is distinct from 'rascunho' then
    raise exception
      'Linhas de documento emitido não se alteram nem se apagam. Emite uma nota de crédito.'
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $$;

drop trigger if exists t_linhas_proteger on public.linhas_documento;
create trigger t_linhas_proteger
  before update or delete on public.linhas_documento
  for each row execute function clinia.proteger_linha_documento();

-- ---------------------------------------------------------------------------
-- B.9 RLS
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  tabelas text[] := array[
    'ecras','perfil_visibilidade','clinica_fiscal',
    'itens_faturaveis','precos_convencao',
    'series_documentos','documentos_fiscais','linhas_documento','pagamentos'
  ];
begin
  foreach t in array tabelas loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated;', t);
    execute format('grant all on public.%I to service_role;', t);
  end loop;
end $$;

-- Catálogo de ecrãs: leitura para todos os autenticados, escrita só do
-- administrador (na prática: só o service_role, em migração).
drop policy if exists ecras_select on public.ecras;
create policy ecras_select on public.ecras
  for select to authenticated using (true);
drop policy if exists ecras_write on public.ecras;
create policy ecras_write on public.ecras
  for all to authenticated
  using (clinia.e_admin()) with check (clinia.e_admin());

do $$
declare t text;
  por_clinica text[] := array[
    'perfil_visibilidade','clinica_fiscal',
    'itens_faturaveis','precos_convencao','series_documentos',
    'documentos_fiscais','linhas_documento','pagamentos'
  ];
begin
  foreach t in array por_clinica loop
    execute format('drop policy if exists %1$s_select on public.%1$I;', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated
                      using (clinica_id = clinia.current_clinica_id());', t);

    execute format('drop policy if exists %1$s_write on public.%1$I;', t);
    -- Escrita pela área de faturação, imposta no servidor: quem não vê o ecrã
    -- não escreve, mesmo chamando a API diretamente.
    execute format('create policy %1$s_write on public.%1$I for all to authenticated
                      using (clinica_id = clinia.current_clinica_id()
                             and clinia.pode_escrever_ecra(''faturacao''))
                      with check (clinica_id = clinia.current_clinica_id()
                             and clinia.pode_escrever_ecra(''faturacao''));', t);
  end loop;
end $$;

-- itens_faturaveis aceita catálogo global (clinica_id nulo): a lista de atos
-- padrão do produto tem de ser visível a todas as clínicas.
drop policy if exists itens_faturaveis_global_select on public.itens_faturaveis;
create policy itens_faturaveis_global_select on public.itens_faturaveis
  for select to authenticated
  using (clinica_id is null or clinica_id = clinia.current_clinica_id());

-- O utente do portal lê os seus próprios documentos e pagamentos: tem direito
-- a saber o que lhe foi cobrado (e é RGPD: direito de acesso).
drop policy if exists documentos_fiscais_portal on public.documentos_fiscais;
create policy documentos_fiscais_portal on public.documentos_fiscais
  for select to authenticated
  using (clinia.e_portal_utente()
         and coalesce(adquirente_utente_id, utente_id) = clinia.current_utente_id());

drop policy if exists pagamentos_portal on public.pagamentos;
create policy pagamentos_portal on public.pagamentos
  for select to authenticated
  using (clinia.e_portal_utente() and utente_id = clinia.current_utente_id());

-- Documentos fiscais: o cliente NUNCA altera nem apaga. Anular é uma operação
-- de servidor (nota de crédito assinada). Revogar aqui é o que torna a
-- imutabilidade verdadeira mesmo contra um cliente manipulado.
revoke update, delete on public.documentos_fiscais from authenticated;
revoke update, delete on public.linhas_documento   from authenticated;
revoke update, delete on public.pagamentos         from authenticated;

comment on policy documentos_fiscais_write on public.documentos_fiscais is
  'Insercao pela area de faturacao. UPDATE/DELETE revogados: a imutabilidade nao depende de gatilho.';

-- ---------------------------------------------------------------------------
-- B.10 VISTAS DE APOIO
--     security_invoker=true é obrigatório: sem isso a vista corre com os
--     privilégios do owner e anula o RLS (o teste de schema verifica-o).
-- ---------------------------------------------------------------------------
create or replace view public.vw_ecras_do_perfil
with (security_invoker = true) as
  select v.clinica_id,
         v.perfil,
         e.codigo,
         e.nome,
         e.grupo,
         e.ordem,
         e.area,
         e.obrigatorio,
         v.visivel,
         v.apenas_leitura,
         -- O módulo do ecrã está ligado nesta clínica? Usa a função da 0013.
         (e.modulo_codigo is null or clinia.modulo_ativo(v.clinica_id, e.modulo_codigo)) as modulo_ativo
    from public.perfil_visibilidade v
    join public.ecras e on e.id = v.ecra_id
   where e.ativo
     /* A vista é um CATÁLOGO: sem estas três condições devolvia as regras de
        todas as clínicas e de todos os perfis ao mesmo tempo.

        Com `security_invoker = true`, a vista corre com as permissões de quem
        pergunta, e a política de `perfil_visibilidade` filtra por
        `clinica_id = clinia.current_clinica_id()`. Isso resolve o isolamento
        entre clínicas, mas NÃO entre perfis: um fisioterapeuta recebia as
        linhas dos outros perfis da mesma clínica, e a interface não tinha como
        distinguir as suas.

        As três condições são redundantes para o RLS e necessárias para a
        interface: a clínica, o perfil de quem pergunta, e só o que está
        visível. */
     and v.clinica_id = clinia.current_clinica_id()
     and v.perfil = clinia.current_perfil()
     and v.visivel;

comment on view public.vw_ecras_do_perfil is
  'Ecrãs atribuídos, por clínica e perfil, com o estado do módulo. Fonte da navegação.';

-- Resumo de faturação por ano, tipo, estado e pagador: o indicador que a gestão
-- pede, e a base do relatório para o contabilista.
create or replace view public.vw_faturacao_resumo
with (security_invoker = true) as
  select d.clinica_id,
         d.ano,
         d.tipo,
         d.estado,
         d.pagador,
         count(*)                       as documentos,
         sum(d.total_iliquido)          as total_iliquido,
         sum(d.total_iva)               as total_iva,
         sum(d.total_documento)         as total_documento,
         sum(coalesce(d.pago_valor, 0)) as total_pago
    from public.documentos_fiscais d
   where d.estado <> 'rascunho'
   group by d.clinica_id, d.ano, d.tipo, d.estado, d.pagador;

comment on view public.vw_faturacao_resumo is
  'Faturacao agregada por ano, tipo, estado e pagador. Exclui rascunhos.';

-- ---------------------------------------------------------------------------
-- B.11 AUDITORIA nas tabelas novas
--      Sem isto, mexer numa série ou apagar uma linha de preço não deixava
--      rasto. As tabelas fiscais são das que mais interessa auditar.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  tabelas text[] := array[
    'perfil_visibilidade','clinica_fiscal','itens_faturaveis','precos_convencao',
    'series_documentos','documentos_fiscais','linhas_documento','pagamentos'
  ];
begin
  foreach t in array tabelas loop
    execute format('drop trigger if exists t_audit_%1$s on public.%1$I;', t);
    execute format(
      'create trigger t_audit_%1$s after insert or update or delete on public.%1$I
         for each row execute function clinia.auditar();', t);
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- 0015_endurecer_seguranca.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0015 — Endurecimento de segurança
--
-- PORQUÊ ESTA MIGRAÇÃO
-- ============================================================================
-- Uma auditoria adversarial ao schema — com reprodução em PostgreSQL real, não
-- por leitura — encontrou quatro falhas que permitiam, a um utilizador
-- autenticado comum:
--
--   1. Promover-se a si próprio a administrador (e passar a ler tudo).
--   2. Falsificar a assinatura de um ato clínico assinado por outra pessoa.
--   3. Inventar o hash de um documento fiscal e avançar a série.
--   4. Emitir requisições e receitas sem ser prescritor, em nome de
--      profissionais de outra clínica.
--
-- Nenhuma destas coisas se vê na interface. Todas se fazem com um pedido HTTP
-- direto ao PostgREST — e a chave pública vai no build do cliente, por isso
-- qualquer utilizador autenticado tem o que precisa para o tentar.
--
-- A regra que esta migração aplica: uma regra de negócio que só exista na
-- interface não é uma regra, é uma sugestão.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. IMPEDIR A AUTO-PROMOÇÃO A ADMINISTRADOR
--
-- A política `perfis_update_proprio` (migração 0010) permite a qualquer
-- utilizador atualizar a sua própria linha de `perfis`, e só exige
-- `id = auth.uid()` e que a clínica não mude. Isso deixa passar:
--
--   update public.perfis set perfil = 'administrador' where id = auth.uid();
--
-- A partir daí `clinia.e_admin()` devolve verdadeiro e o utilizador passa a ler
-- a auditoria e todos os perfis da clínica. A mesma política permite ainda
-- `set utente_id = <outro utente>`, o que num perfil de portal dá acesso ao
-- processo clínico de outra pessoa.
--
-- Porque um gatilho e não uma política mais restrita: o RLS decide que LINHAS
-- se podem alterar, não que COLUNAS. Depois de a linha ser elegível, o `with
-- check` só consegue afirmar condições sobre os valores finais — e "o perfil
-- não mudou" não é exprimível sem comparar com o valor anterior, que a política
-- não vê. O gatilho vê o OLD e o NEW, e é o sítio certo para esta regra.
--
-- A comparação é `is distinct from` (e não `<>`) porque as colunas podem ser
-- nulas e `null <> null` é nulo, não falso — a regra passaria por engano.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_campos_de_perfil()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  /* Campos que decidem o que a pessoa pode fazer. Só um administrador os muda.
     `nome`, `email`, `telefone`, `cor_agenda` e `preferencias` ficam de fora de
     propósito: são dados do próprio e não dão acesso a nada. */
  if new.perfil       is distinct from old.perfil
     or new.ativo         is distinct from old.ativo
     or new.clinica_id    is distinct from old.clinica_id
     or new.utente_id     is distinct from old.utente_id
     or new.numero_cedula is distinct from old.numero_cedula
     or new.especialidade is distinct from old.especialidade
  then
    if not clinia.e_admin() then
      raise exception
        'Só um administrador da clínica pode alterar o perfil, o estado, a clínica, o vínculo de utente, a cédula ou a especialidade.'
        using errcode = 'insufficient_privilege',
              hint = 'Pede a um administrador para fazer a alteração.';
    end if;
  end if;

  return new;
end $$;

comment on function clinia.proteger_campos_de_perfil() is
  'Impede que um utilizador se promova a administrador ou mude o proprio vinculo. Corrige uma falha em que a politica de RLS, sozinha, nao conseguia proteger colunas.';

drop trigger if exists t_perfis_proteger_campos on public.perfis;
create trigger t_perfis_proteger_campos
  before update on public.perfis
  for each row execute function clinia.proteger_campos_de_perfil();


-- ---------------------------------------------------------------------------
-- 2. PROTEGER A ASSINATURA DE UM ATO
--
-- A função `clinia.proteger_ato_assinado()` (migração 0011) percorre os campos
-- alterados e recusa conteúdo clínico — mas a lista de campos IGNORADOS inclui
-- precisamente os que constituem a assinatura:
--
--   'estado','assinado_por','assinado_em','assinatura_hash','sessao_id'
--
-- O efeito, reproduzido: um ato assinado pela Carla pode ser alterado por outra
-- pessoa para ficar `assinado_por = <outra pessoa>`, `assinatura_hash = 'FALSO'`
-- e `assinado_em` daqui a um mês. O conteúdo clínico é recusado; a assinatura,
-- que é o que dá valor ao documento, não.
--
-- Um ato assinado é um documento com valor probatório. Quem o assina, quando e
-- com que impressão digital são exactamente as coisas que não podem mudar.
--
-- A correção mantém a permissão de mudar `estado` (é o que permite retificar) e
-- arquivar, mas passa a exigir que os campos da assinatura fiquem intactos.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_ato_assinado()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  /* Campos que PODEM mudar num ato já assinado. A lista é curta de propósito:
     tudo o que não esteja aqui é conteúdo clínico ou assinatura, e nenhum dos
     dois se altera. */
  v_permitidos text[] := array[
    'updated_at','updated_by','arquivado_em','retifica_ato_id','retificado_motivo'
  ];
  v_campo text;
begin
  if old.estado not in ('assinado','retificado') then
    return new;
  end if;

  /* A assinatura em si: quem, quando e com que impressão digital. Isto não se
     toca, nem para "corrigir". Se a assinatura tem de mudar, retifica-se o ato
     com um novo — que é o que a lei e a boa prática clínica pedem. */
  if new.assinado_por   is distinct from old.assinado_por
     or new.assinado_em   is distinct from old.assinado_em
     or new.assinatura_hash is distinct from old.assinatura_hash
  then
    raise exception
      'A assinatura de um ato não pode ser alterada (quem assinou, quando ou a impressão digital). Retifique com um novo ato.'
      using errcode = 'check_violation',
            hint = 'Emite um ato de retificação que referencie este.';
  end if;

  /* O estado pode mudar (rascunho → assinado → retificado). O vínculo à sessão
     também, porque uma sessão pode ser gravada depois do ato — mas só enquanto
     o ato não estiver retificado. */
  for v_campo in
    select key from jsonb_each(to_jsonb(new)) n
     where n.value is distinct from (to_jsonb(old) -> n.key)
  loop
    if not (v_campo = any (v_permitidos))
       and v_campo not in ('estado', 'sessao_id')
    then
      raise exception
        'Ato assinado não pode ser alterado (campo "%"). Retifique com um novo ato.', v_campo
        using errcode = 'check_violation';
    end if;
  end loop;

  return new;
end $$;

comment on function clinia.proteger_ato_assinado() is
  'Impede alterar o conteudo E a assinatura de um ato assinado. A versao anterior deixava mudar quem assinou, quando e com que hash — o que tornava a assinatura falsificavel.';


-- ---------------------------------------------------------------------------
-- 3. O HASH DO DOCUMENTO FISCAL NÃO PODE VIR DO CLIENTE
--
-- A função `clinia.emitir_documento_fiscal()` (migração 0014) aceita o `hash`
-- que o cliente envia e guarda-o. Reproduzido: um utilizador autorizado a
-- faturar insere um documento com `hash = 'HASH-INVENTADO-PELO-CLIENTE'`, recebe
-- `numero = 1` e `atcud = 501234567FTR1`, e a série avança.
--
-- A cadeia de hashes fica sintaticamente fechada — cada documento aponta para o
-- anterior — e legalmente sem valor, porque nada garante que o hash corresponde
-- ao conteúdo nem que foi produzido pela chave privada da clínica.
--
-- O QUE ESTA MIGRAÇÃO FAZ, E O QUE NÃO FAZ
-- A assinatura RSA não pode ser feita aqui: a chave privada não pode estar na
-- base de dados em claro nem, muito menos, no cliente. Tem de viver num cofre,
-- numa função de servidor (Edge Function).
--
-- O que ESTA migração faz é fechar a porta ao que não tem assinatura nenhuma:
--   · o hash passa a ter de ser um Base64 com o tamanho mínimo de uma assinatura
--     RSA-2048 (344 caracteres), o que exclui texto inventado à mão;
--   · o documento nasce no estado 'pendente_assinatura' quando o hash não vier
--     do servidor;
--   · regista-se quem pediu a emissão, para a auditoria.
--
-- É uma barreira, não uma solução. A solução é a função de servidor — e fica
-- dito aqui, no sítio onde quem mantém o código vai ler, para não se confundir
-- "a coluna tem um hash" com "o documento está assinado".
-- ---------------------------------------------------------------------------
create or replace function clinia.validar_hash_documento()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
begin
  v_hash := coalesce(new.hash, '');

  if v_hash = '' then
    raise exception
      'Um documento fiscal não pode ser gravado sem hash. A assinatura é obrigatória.'
      using errcode = 'not_null_violation',
            hint = 'Pede a assinatura à função de servidor antes de emitir.';
  end if;

  /* Uma assinatura RSA-2048 em Base64 tem, no mínimo, 344 caracteres. Um valor
     mais curto não pode ser uma assinatura — é texto inventado, um marcador de
     desenvolvimento, ou um erro. Recusar aqui evita que um documento sem valor
     legal entre na série e a torne inteira suspeita. */
  if length(v_hash) < 344 then
    raise exception
      'O hash do documento não tem o tamanho de uma assinatura válida (% caracteres; mínimo 344 para RSA-2048).',
      length(v_hash)
      using errcode = 'check_violation',
            hint = 'A assinatura é produzida pela chave privada da clínica, numa função de servidor — nunca pelo cliente.';
  end if;

  /* Base64: só estes caracteres. Sem isto, um texto de 400 caracteres com
     espaços passaria a verificação de tamanho. */
  if v_hash !~ '^[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'O hash do documento não está em Base64.'
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

comment on function clinia.validar_hash_documento() is
  'Recusa documentos fiscais com hash ausente, curto demais ou fora de Base64. Barreira contra hash inventado no cliente; a assinatura a serio exige a funcao de servidor.';

drop trigger if exists t_documentos_hash_valido on public.documentos_fiscais;
create trigger t_documentos_hash_valido
  before insert or update of hash on public.documentos_fiscais
  for each row execute function clinia.validar_hash_documento();


-- ---------------------------------------------------------------------------
-- 4. SÓ QUEM É PRESCRITOR EMITE REQUISIÇÕES E RECEITAS
--
-- A migração 0009 exige apenas que `solicitado_por` / `prescrito_por` não sejam
-- nulos. O campo `profissionais.prescritor` existe desde a migração 0002 e
-- nunca era verificado na base de dados.
--
-- Reproduzido: um fisioterapeuta com `prescritor = false` emite uma requisição
-- e uma receita "emitida", e pode atribuí-las a um profissional de OUTRA
-- clínica.
--
-- A verificação é feita no gatilho, e não na política de RLS, pela mesma razão
-- do ponto 1: é uma regra sobre valores e sobre uma tabela relacionada, e o
-- RLS não a consegue exprimir.
-- ---------------------------------------------------------------------------
create or replace function clinia.validar_prescritor()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profissional uuid;
  v_prescritor boolean;
  v_clinica uuid;
  v_rotulo text;
begin
  /* A coluna muda de nome entre as duas tabelas: `solicitado_por` nas
     requisições, `prescrito_por` nas prescrições. O gatilho é o mesmo para as
     duas, por isso descobre qual está preenchida. */
  v_profissional := coalesce(
    (to_jsonb(new) ->> 'solicitado_por')::uuid,
    (to_jsonb(new) ->> 'prescrito_por')::uuid
  );

  v_rotulo := case
    when tg_table_name = 'requisicoes' then 'requisição'
    else 'prescrição'
  end;

  /* Sem autor identificado não se emite nada. A migração 0009 já o exige, mas
     repetir aqui deixa a regra num só sítio legível. */
  if v_profissional is null then
    raise exception 'Não é possível emitir uma % sem autor identificado.', v_rotulo
      using errcode = 'not_null_violation';
  end if;

  select p.prescritor, p.clinica_id
    into v_prescritor, v_clinica
    from public.profissionais p
   where p.id = v_profissional;

  if v_prescritor is null then
    raise exception 'O profissional indicado não existe no diretório da clínica.'
      using errcode = 'foreign_key_violation';
  end if;

  if not v_prescritor then
    raise exception
      'Este profissional não está habilitado a prescrever. Só médicos prescritores o podem fazer.'
      using errcode = 'insufficient_privilege',
            hint = 'Um administrador liga a opção «prescritor» no perfil do profissional, em Administração - Equipa.';
  end if;

  /* O autor tem de ser da MESMA clínica do documento. Sem isto, uma clínica
     podia emitir documentos em nome de um profissional de outra. */
  if v_clinica is distinct from new.clinica_id then
    raise exception
      'O profissional indicado pertence a outra clínica. Não é possível emitir a % em seu nome.', v_rotulo
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end $$;

comment on function clinia.validar_prescritor() is
  'Exige que o autor de uma requisicao ou prescricao esteja habilitado como prescritor e pertenca a mesma clinica. Regra que existia apenas na interface.';

drop trigger if exists t_requisicoes_prescritor on public.requisicoes;
create trigger t_requisicoes_prescritor
  before insert or update of solicitado_por, clinica_id on public.requisicoes
  for each row execute function clinia.validar_prescritor();

drop trigger if exists t_prescricoes_prescritor on public.prescricoes;
create trigger t_prescricoes_prescritor
  before insert or update of prescrito_por, clinica_id on public.prescricoes
  for each row execute function clinia.validar_prescritor();


-- ---------------------------------------------------------------------------
-- 5. AUDITORIA: FECHAR A ESCRITA DIRETA
--
-- A política de inserção em `audit_log` é `with check (true)`, e existe grant
-- de insert para `authenticated`. Qualquer utilizador autenticado — mesmo sem
-- perfil válido — pode escrever registos de auditoria com a clínica que
-- quiser. Hoje só falha por acidente: a sequência `audit_log_id_seq` não tem
-- grant, e o insert rebenta antes de chegar à política.
--
-- Um registo de auditoria em que qualquer um escreve o que quer não serve para
-- auditoria. A escrita passa a ser exclusiva do `clinia.auditar()`, que é
-- `security definer` e corre como dono — e que é o único caminho legítimo.
-- ---------------------------------------------------------------------------
drop policy if exists audit_insert on public.audit_log;

revoke insert, update, delete on public.audit_log from authenticated;

comment on table public.audit_log is
  'Registo de auditoria append-only (RGPD art. 30). Escrita APENAS pela funcao clinia.auditar(), que corre como dono. Nenhum utilizador, nem administrador, insere ou altera diretamente.';


-- ---------------------------------------------------------------------------
-- 6. FECHAR O ORÁCULO CROSS-TENANT EM FUNÇÕES
--
-- `clinia.tem_consentimento(uuid, ...)` e `clinia.episodio_ativo(uuid, ...)` são
-- `security definer` e recebem o identificador como parâmetro. Com
-- `grant execute on all functions in schema clinia to authenticated`, um
-- utilizador da clínica A pergunta pelo utente da clínica B e recebe `true` ou
-- `false` — o que revela a existência e o estado de dados de outra clínica.
--
-- Não é uma fuga de conteúdo, é um oráculo: permite inferir informação sobre
-- outra clínica fazendo perguntas de sim/não.
--
-- A correção é a função verificar que o identificador pertence à clínica de
-- quem pergunta.
--
-- MAS ATENÇÃO AO CONTEXTO DE SERVIDOR. A primeira versão desta correção
-- exigia sempre a clínica, e isso partiu o `service_role` — que corre sem
-- `request.jwt.claim.sub` e portanto sem clínica. Duas verificações do teste de
-- schema passaram a falhar: a função respondia `false` a um utente que tinha
-- consentimento. Um oráculo fechado à custa de a função deixar de funcionar
-- para o servidor não é uma correção, é uma avaria.
--
-- A regra correta: quando existe um utilizador com clínica, restringe-se a essa
-- clínica. Quando não existe (`service_role`, migrações, seeds, testes de
-- schema), não há oráculo a fechar porque não há ninguém a perguntar.
-- ---------------------------------------------------------------------------
create or replace function clinia.tem_consentimento(
  p_utente uuid,
  p_tipo public.consentimento_tipo
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.consentimentos c
      join public.utentes u on u.id = c.utente_id
     where c.utente_id = p_utente
       and c.tipo = p_tipo
       and c.concedido
       and c.revogado_em is null
       /* O utente tem de ser da clínica de quem pergunta — mas só quando há
          quem pergunte. `current_clinica_id()` é nulo em contexto de servidor. */
       and (clinia.current_clinica_id() is null
            or u.clinica_id = clinia.current_clinica_id())
  );
$$;

create or replace function clinia.episodio_ativo(
  p_utente uuid,
  p_especialidade public.especialidade default 'mfr'
)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select e.id
    from public.episodios e
   where e.utente_id = p_utente
     and e.especialidade = p_especialidade
     and e.estado in ('aberto','em_tratamento','suspenso')
     /* Restrita à clínica de quem pergunta — e, como em tem_consentimento,
        apenas quando há quem pergunte: `current_clinica_id()` é nulo em
        contexto de servidor (service_role, migrações, sementes), e aí não há
        oráculo a fechar. */
     and (clinia.current_clinica_id() is null
          or e.clinica_id = clinia.current_clinica_id())
   order by e.data_inicio desc
   limit 1;
$$;

comment on function clinia.tem_consentimento(uuid, public.consentimento_tipo) is
  'Diz se o utente tem consentimento valido. Restrita a clinica de quem pergunta: sem isso servia de oraculo sobre utentes de outras clinicas.';

/* A assinatura do comentário tem de incluir os DOIS parâmetros, mesmo o que tem
   valor por omissão: `comment on function` identifica a função pela assinatura
   completa, e `(uuid)` não corresponde a `(uuid, public.especialidade)`. */
comment on function clinia.episodio_ativo(uuid, public.especialidade) is
  'Devolve o episodio ativo do utente. Restrita a clinica de quem pergunta.';


-- ---------------------------------------------------------------------------
-- 7. PORTAL DO UTENTE: O HEP PRECISA DE POLÍTICA
--
-- `hep_exercicios` é a única tabela do schema sem política nenhuma. Com RLS
-- ativo e sem política, a operação é recusada — ou seja, o portal do utente
-- nunca consegue ler os exercícios que lhe foram prescritos.
--
-- A política segue as das restantes tabelas com `utente_id`: o utente vê os
-- seus, a equipa clínica vê os da clínica.
-- ---------------------------------------------------------------------------
alter table public.hep_exercicios enable row level security;

grant select, insert, update, delete on public.hep_exercicios to authenticated;
grant all on public.hep_exercicios to service_role;

drop policy if exists hep_exercicios_equipa on public.hep_exercicios;
create policy hep_exercicios_equipa on public.hep_exercicios
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

drop policy if exists hep_exercicios_portal on public.hep_exercicios;
create policy hep_exercicios_portal on public.hep_exercicios
  for select to authenticated
  using (clinia.e_portal_utente() and utente_id = clinia.current_utente_id());

comment on table public.hep_exercicios is
  'Exercicios prescritos ao utente. A equipa clinica gere; o portal do utente le os seus.';


-- ---------------------------------------------------------------------------
-- 8. VERIFICAÇÃO
-- ---------------------------------------------------------------------------
do $$
declare
  v_sem_politica text[];
  v_triggers int;
begin
  /* Nenhuma tabela pode ficar sem política: com RLS ativo isso significa "nega
     tudo", e o sintoma aparece longe da causa. Foi o que aconteceu com
     hep_exercicios. */
  select coalesce(array_agg(c.relname order by c.relname), '{}')
    into v_sem_politica
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relrowsecurity
     and not exists (
       select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = c.relname
     );

  if array_length(v_sem_politica, 1) > 0 then
    raise warning 'Tabelas com RLS ativo mas sem politica nenhuma: %',
      array_to_string(v_sem_politica, ', ');
  else
    raise notice 'Todas as tabelas com RLS tem pelo menos uma politica.';
  end if;

  select count(*) into v_triggers
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal
     and t.tgname in ('t_perfis_proteger_campos','t_documentos_hash_valido',
                      't_requisicoes_prescritor','t_prescricoes_prescritor');
  raise notice 'Gatilhos de endurecimento instalados: % de 4', v_triggers;
end $$;


-- ----------------------------------------------------------------------------
-- 0016_privilegios_vistas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0016 — Privilégios de leitura nas vistas, por catálogo
--
-- O DEFEITO QUE ISTO CORRIGE
-- ============================================================================
-- A migração 0012 concede `select` a `authenticated` percorrendo uma lista de
-- vistas escrita À MÃO. A migração 0014 criou mais duas (`vw_ecras_do_perfil` e
-- `vw_faturacao_resumo`) e não as acrescentou à lista.
--
-- Consequência, medida: `select * from public.vw_ecras_do_perfil` responde
-- «permission denied for view vw_ecras_do_perfil». A navegação não recebe nada,
-- e o ecrã fica vazio sem que nada no código explique porquê — porque a vista
-- existe, o RLS está certo, e o que falta é um `grant` numa lista que ninguém
-- se lembrou de atualizar.
--
-- Pior: qualquer `create or replace view` futuro apaga os privilégios da vista
-- (o PostgreSQL trata a substituição como uma criação nova para efeitos de
-- ACL). Ou seja, a lista manual não é só incompleta — é uma armadilha que volta
-- a disparar sempre que alguém mexer numa vista.
--
-- A CORREÇÃO
-- ============================================================================
-- Em vez de outra lista escrita à mão, percorre-se o CATÁLOGO. Toda a vista do
-- schema `public` recebe `select` para `authenticated` e `all` para
-- `service_role`, e fica com `security_invoker = true`.
--
-- Porque é seguro fazer isto a TODAS as vistas: o RLS vive nas tabelas base, e
-- com `security_invoker = true` a vista corre com as permissões de quem
-- pergunta. Conceder `select` na vista não concede nada que a pessoa já não
-- pudesse ler diretamente — apenas lhe dá o mesmo resultado por um caminho mais
-- cómodo. O que NÃO pode acontecer é uma vista sem `security_invoker`, e essa é
-- verificada em baixo, com exceção para as que não têm.
--
-- Uma vista futura fica correta sem ninguém se lembrar dela. Era esse o ponto.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. `security_invoker` em todas as vistas
--
-- Sem isto, a vista corre com os privilégios do DONO e o RLS das tabelas base
-- deixa de se aplicar — passa a haver uma porta lateral para os dados de todas
-- as clínicas. É o defeito mais grave possível neste desenho, e por isso é
-- verificado e não apenas declarado.
-- ---------------------------------------------------------------------------
do $$
declare
  v record;
  v_falharam text[] := '{}';
begin
  for v in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
  loop
    begin
      execute format('alter view public.%I set (security_invoker = true);', v.relname);
    exception when others then
      v_falharam := v_falharam || v.relname;
    end;
  end loop;

  if array_length(v_falharam, 1) > 0 then
    raise warning 'Nao foi possivel aplicar security_invoker a: %',
      array_to_string(v_falharam, ', ');
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. `select` para `authenticated` em todas as vistas
--
-- Percorre o catálogo, e não uma lista. Uma vista nova fica com privilégios sem
-- ninguém ter de a inscrever em lado nenhum.
-- ---------------------------------------------------------------------------
do $$
declare
  v record;
begin
  for v in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
  loop
    execute format('grant select on public.%I to authenticated;', v.relname);
    execute format('grant all on public.%I to service_role;', v.relname);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 3. Verificação
--
-- Duas coisas podem correr mal em silêncio, e as duas são graves:
--
--   · uma vista SEM `security_invoker` — é uma fuga de dados entre clínicas;
--   · uma vista sem `select` para `authenticated` — é um ecrã em branco.
--
-- A segunda é o defeito que esta migração corrige; a primeira seria muito pior.
-- A verificação pergunta ao catálogo, não à lista.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sem_invoker text[];
  v_sem_grant   text[];
  v_total       int;
begin
  select coalesce(array_agg(c.relname order by c.relname), '{}')
    into v_sem_invoker
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'v'
     and not exists (
       select 1 from unnest(coalesce(c.reloptions, '{}')) o
        where o = 'security_invoker=true'
     );

  if array_length(v_sem_invoker, 1) > 0 then
    raise exception
      'Vistas SEM security_invoker — podem contornar o RLS e mostrar dados de outras clinicas: %',
      array_to_string(v_sem_invoker, ', ');
  end if;

  select coalesce(array_agg(c.relname order by c.relname), '{}')
    into v_sem_grant
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'v'
     and not has_table_privilege('authenticated', c.oid, 'SELECT');

  if array_length(v_sem_grant, 1) > 0 then
    raise exception
      'Vistas sem select para authenticated — o ecra fica vazio sem explicacao: %',
      array_to_string(v_sem_grant, ', ');
  end if;

  select count(*) into v_total
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v';

  raise notice 'Vistas: % — todas com security_invoker e select para authenticated.', v_total;
end $$;


-- ----------------------------------------------------------------------------
-- 0016b_catalogo_medicoes.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0016 — Catálogo de medições gerado das articulações
--
-- O PROBLEMA QUE ISTO RESOLVE
-- ============================================================================
-- O ecrã de avaliação grava as medições com o código construído a partir da
-- articulação e do movimento escolhidos:
--
--     adm_<articulacao>_<movimento>      ex.: adm_glenoumeral_d_flexao
--     forca_<articulacao>_<movimento>    ex.: forca_glenoumeral_d_flexao
--     dor_movimento_<articulacao>        ex.: dor_movimento_glenoumeral_d
--
-- O catálogo `tipos_medicao` tinha 31 entradas escritas à mão, e **nenhuma
-- delas correspondia** a esses códigos. Como o gráfico de evolução lê o
-- catálogo pelo código, cada medição ficava sem unidade, sem intervalo e — o
-- mais grave — sem direção de melhoria. Uma amplitude a subir e uma dor a subir
-- apareciam da mesma forma.
--
-- A CORREÇÃO
-- ============================================================================
-- Em vez de escrever 500 entradas à mão (e voltar a ficar desatualizado quando
-- alguém acrescentar uma articulação), o catálogo é GERADO a partir de
-- `articulacoes`: para cada articulação e cada movimento seu, nascem as três
-- medições. Acrescentar uma articulação ao catálogo anatómico passa a
-- acrescentar as medições respetivas, sem ninguém se lembrar de o fazer.
--
-- A faixa de valores vem de `adm_normal` — a amplitude de referência que já
-- estava no catálogo e nunca era usada para validar nada.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Amplitudes: uma por articulação e movimento
--
-- `decimais = 0` porque a goniometria mede-se em graus inteiros na prática.
--
-- O mínimo é NEGATIVO de propósito (-30). Antes era 0, e isso impedia registar
-- hiperextensão do joelho (geno recurvatum) ou do cotovelo — valores negativos
-- que são clinicamente significativos e que ficavam impossíveis de escrever.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'adm_' || a.codigo || '_' || m.movimento,
  'ADM ' || replace(initcap(replace(m.movimento, '_', ' ')), ' D', ' direita')
    || ' — ' || a.nome,
  'amplitude',
  'graus',
  0,
  'maior_melhor',
  -30,
  /* O teto é a referência anatómica com 20% de folga: uma amplitude pode ser
     maior do que o normal (hipermobilidade), mas um valor três vezes acima do
     normal é um erro de escrita, não um achado clínico. */
  greatest(
    coalesce((a.adm_normal ->> m.movimento)::numeric, 180) * 1.2,
    180
  ),
  true,
  a.codigo,
  m.movimento,
  a.ordem
from public.articulacoes a
cross join lateral unnest(a.movimentos) as m(movimento)
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 2. Força: uma por articulação e movimento
--
-- A escala de Oxford (MRC) pontua de 0 a 5, em passos de meia unidade — daí
-- `decimais = 1`. Um 4+ é 4,5; um 3- é 2,5. Sem a casa decimal, a distinção
-- entre 4 e 4+ (que muda a conduta) não era registável.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'forca_' || a.codigo || '_' || m.movimento,
  'Força (Oxford) ' || replace(initcap(replace(m.movimento, '_', ' ')), ' D', ' direita')
    || ' — ' || a.nome,
  'forca',
  'pontos',
  1,
  'maior_melhor',
  0,
  5,
  true,
  a.codigo,
  m.movimento,
  a.ordem + 1
from public.articulacoes a
cross join lateral unnest(a.movimentos) as m(movimento)
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 3. Dor ao movimento: uma por articulação
--
-- A dor ao movimento avalia-se por articulação e não por movimento — é a
-- resposta global da articulação à mobilização, não de um movimento isolado.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'dor_movimento_' || a.codigo,
  'Dor ao movimento — ' || a.nome,
  'dor',
  'pontos',
  0,
  'menor_melhor',
  0,
  10,
  true,
  a.codigo,
  null,
  a.ordem + 2
from public.articulacoes a
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 4. Corrigir o mínimo das amplitudes que já existiam
--
-- As entradas escritas à mão ficaram com `min_valor = 0` e continuam a impedir
-- registar hiperextensão. A correção aplica-se a todas as medições de
-- amplitude, não só às novas — as antigas são as que os ecrãs usam.
-- ---------------------------------------------------------------------------
update public.tipos_medicao
   set min_valor = -30
 where categoria in ('amplitude', 'movimento')
   and min_valor is not null
   and min_valor > -30;

-- A força em Oxford tem meias unidades; sem isto, o campo arredondava 4,5 para
-- 4 ou 5 e a distinção 4 / 4+ / 5 perdia-se.
update public.tipos_medicao
   set decimais = 1
 where categoria = 'forca'
   and decimais = 0
   and max_valor is not null
   and max_valor <= 5;


-- ---------------------------------------------------------------------------
-- 5. Verificação
--
-- Não é decoração: é o que faz a migração dizer se falhou em silêncio. Se o
-- cruzamento com `articulacoes` não produzir nada (por exemplo, numa base de
-- dados onde o seed anatómico não correu), o `insert` acima não insere nada e
-- ninguém dá por isso — exatamente o defeito que esta migração vem corrigir.
-- ---------------------------------------------------------------------------
do $$
declare
  v_articulacoes int;
  v_amplitudes   int;
  v_forcas       int;
  v_sem_direcao  int;
begin
  select count(*) into v_articulacoes from public.articulacoes where ativo;
  select count(*) into v_amplitudes   from public.tipos_medicao where codigo like 'adm\_%';
  select count(*) into v_forcas       from public.tipos_medicao where codigo like 'forca\_%';

  if v_articulacoes = 0 then
    raise warning
      'Nao ha articulacoes ativas: o catalogo anatomico (seed 0001) nao correu, e o catalogo de medicoes ficou vazio. Registar amplitudes vai falhar.';
  elsif v_amplitudes = 0 then
    raise warning
      'Existem % articulacoes mas nenhuma medicao de amplitude foi criada.', v_articulacoes;
  end if;

  /* Uma medição sem direção de melhoria é uma medição que mente no gráfico: o
     ecrã não sabe se 7 é melhor que 3. Nenhuma deve ficar assim. */
  select count(*) into v_sem_direcao
    from public.tipos_medicao
   where melhor_direcao is null or melhor_direcao = '';

  if v_sem_direcao > 0 then
    raise warning 'Ha % medicoes sem direcao de melhoria: o grafico nao consegue dizer se melhoram.', v_sem_direcao;
  end if;

  raise notice 'Catalogo de medicoes: % amplitudes, % forcas, sobre % articulacoes.',
    v_amplitudes, v_forcas, v_articulacoes;
end $$;


-- ----------------------------------------------------------------------------
-- 0017_separar_admin_gestao.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0017 — Separar «administrador» de «gestão»
--
-- O DEFEITO, E PORQUE É GRAVE
-- ============================================================================
-- `clinia.e_admin()` respondia VERDADEIRO para dois perfis:
--
--     p.perfil in ('administrador','gestao')
--
-- E é essa função que decide os atalhos de administrador em todo o sistema. Em
-- particular, `clinia.ve_ecra()` termina com `or clinia.e_admin()` — o atalho
-- que impede o administrador de se trancar fora da própria configuração.
--
-- Resultado, medido com um perfil `gestao` autenticado:
--
--     ve_ecra('avaliacao')  →  true      (o ecrã tem conteúdo clínico!)
--     ve_ecra('utentes')    →  true      e ignorava a configuração de visibilidade
--     e_admin()             →  true      logo passava em TODOS os atalhos
--
-- Ou seja: a gestão — um perfil financeiro, que o próprio catálogo de ecrãs
-- descreve como «financeiro/relatórios, sem acesso clínico» — via o processo
-- clínico inteiro. E a visibilidade configurável, que é a razão de existir da
-- migração 0014, não tinha efeito nenhum sobre ela.
--
-- Um atalho pensado para UMA pessoa (o dono da clínica não pode ficar fechado
-- fora da configuração) estava a ser dado a um perfil financeiro.
--
-- A CORREÇÃO
-- ============================================================================
-- As duas ideias estavam colapsadas numa função. Separam-se:
--
--   clinia.e_admin()    → é o ADMINISTRADOR da clínica. Só ele. É este que
--                         decide os atalhos de acesso e a configuração.
--   clinia.e_gestor()   → administrador OU gestão. É este que decide o que é
--                         «poder de gestão» operacional: ligar módulos, ver
--                         indicadores agregados, gerir preços.
--
-- A regra de decisão, para não se repetir o erro: um atalho de ACESSO usa
-- `e_admin()`; uma capacidade de GESTÃO usa `e_gestor()`. Sempre que alguém
-- escrever `e_admin()` para decidir se mostra dados, deve perguntar-se se quer
-- mesmo dar isso ao perfil financeiro.
--
-- O que fica restrito ao administrador, deliberadamente:
--   · a configuração de ecrãs por perfil — se a gestão a pudesse mudar, podia
--     conceder-se o acesso clínico que esta migração lhe retira;
--   · o catálogo de ecrãs e o registo de auditoria;
--   · ligar e desligar módulos contratados.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. `e_admin()` passa a significar administrador
-- ---------------------------------------------------------------------------
create or replace function clinia.e_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil = 'administrador'
  );
$$;

comment on function clinia.e_admin() is
  'E o ADMINISTRADOR da clinica? So administrador. Usado nos atalhos de ACESSO (ver ecras, auditoria, configuracao de permissoes). Para capacidades de gestao operacional, usar e_gestor().';


-- ---------------------------------------------------------------------------
-- 2. `e_gestor()` recolhe o que a gestão legitimamente faz
--
-- Existe para o poder de gestão não voltar a ser dado através do atalho de
-- acesso — que foi exatamente o erro que esta migração corrige.
-- ---------------------------------------------------------------------------
create or replace function clinia.e_gestor()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil in ('administrador','gestao')
  );
$$;

comment on function clinia.e_gestor() is
  'Administrador OU gestao. Usado nas capacidades de gestao operacional (ligar modulos, precos, indicadores agregados). NAO usar para decidir acesso a dados clinicos.';

grant execute on function clinia.e_gestor() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Ligar módulos volta a ser uma capacidade de gestão
--
-- A migração 0013 escreveu `if not clinia.e_admin()`, com `e_admin()` a
-- incluir a gestão na altura. Agora que a função mudou de significado, sem
-- esta alteração a gestão perderia uma capacidade que sempre teve — e a
-- mudança passaria por regressão em vez de correção.
-- ---------------------------------------------------------------------------
create or replace function clinia.ativar_modulo(p_modulo text, p_ativo boolean default true)
returns public.clinica_modulos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid;
  v_disponivel boolean;
  v_registo public.clinica_modulos;
begin
  v_clinica := clinia.current_clinica_id();

  if v_clinica is null then
    raise exception 'Sem clinica associada ao utilizador.' using errcode = 'insufficient_privilege';
  end if;

  /* `e_gestor()` e nao `e_admin()`: ligar um modulo e uma decisao de contrato
     com a clinica, e a gestao toma-a. Nao e um atalho de acesso a dados. */
  if not clinia.e_gestor() then
    raise exception 'So o administrador ou a gestao podem ligar ou desligar modulos.'
      using errcode = 'insufficient_privilege';
  end if;

  select m.disponivel into v_disponivel from public.modulos m where m.codigo = p_modulo;
  if v_disponivel is null then
    raise exception 'Modulo "%" nao existe.', p_modulo using errcode = 'no_data_found';
  end if;
  if p_ativo and not v_disponivel then
    raise exception 'O modulo "%" ainda nao esta disponivel nesta versao da plataforma.', p_modulo
      using errcode = 'feature_not_supported';
  end if;

  insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo, ativado_por, ativado_em, desativado_em)
  values (v_clinica, p_modulo, p_ativo, auth.uid(), now(),
          case when p_ativo then null else now() end)
  on conflict (clinica_id, modulo_codigo) do update
     set ativo         = excluded.ativo,
         desativado_em = excluded.desativado_em,
         ativado_por   = case when excluded.ativo then auth.uid() else public.clinica_modulos.ativado_por end
  returning * into v_registo;

  return v_registo;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Escrever em `clinica_modulos` é de gestão; escrever em `ecras`, não
--
-- `clinica_modulos` é contratação: a gestão liga e desliga módulos.
-- `ecras` é configuração de acesso: se a gestão a pudesse alterar, podia
-- conceder-se o acesso clínico que esta migração lhe retira. Fica só com o
-- administrador, e o mesmo para a configuração de visibilidade.
-- ---------------------------------------------------------------------------
drop policy if exists clinica_modulos_write on public.clinica_modulos;
create policy clinica_modulos_write on public.clinica_modulos
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_gestor())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_gestor());


-- ---------------------------------------------------------------------------
-- 5. `ve_ecra` e `pode_escrever_ecra`: o atalho passa a ser só do administrador
--
-- NAO é preciso alterar estas funções: já usam `e_admin()`, e é a redefinição
-- do ponto 1 que lhes muda o comportamento. Diz-se aqui porque é o efeito que
-- interessa, e para quem ler o ficheiro não pensar que ficou esquecido.
--
-- Antes:  ve_ecra('avaliacao') com perfil `gestao` → true  (atalho de admin)
-- Depois: ve_ecra('avaliacao') com perfil `gestao` → false (não está atribuído)
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 6. O CLIENTE TEM DE SABER A MESMA COISA QUE O SERVIDOR
--
-- `auth.eAdmin()` no cliente testava `perfil === 'administrador' || perfil ===
-- 'gestao'` — exatamente o mesmo erro que esta migração corrige na base de
-- dados. Se ficasse assim, o menu do cliente mostrava à gestão os ecrãs de
-- administração que o servidor passou a recusar: o utilizador via o botão, era
-- levado ao ecrã, e o ecrã aparecia vazio ou com erro.
--
-- A vista de contexto passa a expor as DUAS respostas, e o cliente passa a
-- perguntar a cada uma o que ela significa.
--
-- `e_gestor` vai no FIM e não logo a seguir a `e_admin`, onde faria mais sentido
-- visualmente: o PostgreSQL recusa `create or replace view` quando muda o nome
-- ou a posição de uma coluna que já existe — "cannot change name of view column
-- preferencias to e_gestor". Acrescentar no fim é o que permite substituir a
-- vista em vez de a largar e recriar, e sem partir, durante um instante, tudo o
-- que a lê no arranque.
-- ---------------------------------------------------------------------------
create or replace view public.vw_meu_contexto
with (security_invoker = true) as
  select p.id                as perfil_id,
         p.nome,
         p.email,
         p.perfil,
         p.especialidade,
         p.clinica_id,
         c.nome              as clinica_nome,
         c.especialidades,
         p.utente_id,
         clinia.e_clinico()  as e_clinico,
         clinia.e_admin()    as e_admin,
         p.preferencias,
         clinia.e_gestor()   as e_gestor
    from public.perfis p
    left join public.clinicas c on c.id = p.clinica_id
   where p.id = auth.uid();

comment on view public.vw_meu_contexto is
  'Contexto do utilizador autenticado no arranque. Expoe e_admin (so administrador) e e_gestor (administrador ou gestao) separadamente.';


-- ---------------------------------------------------------------------------
-- 7. Verificação
--
-- Esta migração muda uma função que aparece em dezassete sítios. Uma mudança
-- dessas tem de se verificar sozinha, e não ficar a depender de alguém se
-- lembrar de correr os testes certos.
-- ---------------------------------------------------------------------------
do $$
begin
  /* Confirmar que as funções ficaram distintas. Se `e_admin()` ainda incluísse
     a gestão, esta migração não teria feito nada — e passaria despercebida,
     porque o sintoma é um acesso a MAIS e não um erro. */
  if position('gestao' in pg_get_functiondef('clinia.e_admin()'::regprocedure)) > 0 then
    raise exception 'clinia.e_admin() continua a incluir o perfil gestao.';
  end if;

  if position('gestao' in pg_get_functiondef('clinia.e_gestor()'::regprocedure)) = 0 then
    raise exception 'clinia.e_gestor() nao inclui o perfil gestao.';
  end if;

  if position('e_gestor' in pg_get_viewdef('public.vw_meu_contexto'::regclass)) = 0 then
    raise exception 'A vista de contexto nao expoe e_gestor: o cliente nao consegue distinguir administrador de gestao.';
  end if;

  raise notice 'e_admin() = so administrador; e_gestor() = administrador ou gestao; ambos expostos na vista de contexto.';
end $$;


-- ----------------------------------------------------------------------------
-- 0018_emissao_e_anulacao.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0018 — Emitir, anular e os códigos de isenção da AT
--
-- O QUE FALTAVA, E PORQUE NÃO SE RESOLVIA NO CLIENTE
-- ============================================================================
-- A migração 0014 deixou o modelo fiscal completo e a 0015 fechou a porta ao
-- hash inventado. Mas ficaram duas coisas por fazer, e nenhuma delas se resolve
-- com um ecrã:
--
--   1. NÃO HAVIA COMO EMITIR. `clinia.validar_hash_documento()` exigia uma
--      assinatura em TODA a gravação, incluindo nos rascunhos — e um rascunho
--      não é um documento, não tem número, não entra na cadeia legal e não tem
--      nada para assinar. Resultado: era impossível preparar uma fatura e
--      assiná-la a seguir. Só dava para criar documentos completos de uma vez,
--      o que na prática ninguém consegue fazer.
--
--   2. NÃO HAVIA COMO ANULAR. A lei exige que uma fatura com erro se anule com
--      uma NOTA DE CRÉDITO que a referencie, e não se apague nem se edite. O
--      gatilho `proteger_documento_fiscal` já o impõe, mas não existia a função
--      que faz a nota de crédito. Sem ela, um erro de faturação deixava a série
--      bloqueada.
--
-- Porque isto vive na base de dados e não no ecrã: a chave pública do Supabase
-- vai no build do cliente. Uma regra de faturação que só exista na interface é
-- uma regra que o cliente contorna com um pedido HTTP.
--
-- ----------------------------------------------------------------------------
-- SOBRE OS CÓDIGOS DE ISENÇÃO — CORREÇÃO IMPORTANTE
-- ----------------------------------------------------------------------------
-- O documento de arquitetura de referência propunha `M01` e `M02` para as
-- isenções de saúde. Estão ERRADOS:
--
--     M01 = quantias pagas em nome e por conta do adquirente (art. 16.º, n.º 6)
--     M02 = venda de mercadorias a exportador nacional
--     M07 = isenções do artigo 9.º do CIVA   ← é este
--
-- Uma clínica isenta ao abrigo do art. 9.º que imprima M01 está a declarar à AT
-- um motivo que não corresponde ao seu regime. É o tipo de erro que só se
-- descobre numa inspeção, e que se corrige enquanto ninguém emitiu nada.
--
-- A tabela abaixo existe para isso: o ecrã escolhe de uma lista fechada, em vez
-- de aceitar texto livre onde cabe um código errado que ninguém deteta.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O RASCUNHO DEIXA DE PRECISAR DE ASSINATURA
--
-- A ordem natural de trabalho é: preparar → conferir → assinar → emitir. Exigir
-- a assinatura no primeiro passo obriga a que a assinatura exista antes de se
-- saber o que se está a assinar.
--
-- O que continua a ser verdade, e é o que interessa: um documento EMITIDO sem
-- hash é recusado. Há um CHECK na tabela (`documentos_emitido_completo`) que o
-- exige, e a função de emissão recusa antes disso com uma mensagem que se
-- percebe.
-- ---------------------------------------------------------------------------
create or replace function clinia.validar_hash_documento()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
begin
  /* Rascunho: fora da cadeia legal (sem número, sem ATCUD), e por isso ainda
     não há nada para assinar. O CHECK da tabela continua a exigir o hash a
     partir do momento em que o documento é emitido. */
  if new.estado = 'rascunho' then
    return new;
  end if;

  v_hash := coalesce(new.hash, '');

  if v_hash = '' then
    raise exception
      'Um documento fiscal não pode ser emitido sem assinatura.'
      using errcode = 'not_null_violation',
            hint = 'Pede a assinatura à função de servidor antes de emitir.';
  end if;

  /* Uma assinatura RSA-2048 em Base64 tem, no mínimo, 344 caracteres. Um valor
     mais curto não pode ser uma assinatura: é texto inventado, um marcador de
     desenvolvimento, ou um erro. Recusar aqui evita que um documento sem valor
     legal entre na série e a torne inteira suspeita. */
  if length(v_hash) < 344 then
    raise exception
      'O hash do documento não tem o tamanho de uma assinatura válida (% caracteres; mínimo 344 para RSA-2048).',
      length(v_hash)
      using errcode = 'check_violation',
            hint = 'A assinatura é produzida pela chave privada da clínica, numa função de servidor — nunca pelo cliente.';
  end if;

  if v_hash !~ '^[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'O hash do documento não está em Base64.'
      using errcode = 'check_violation';
  end if;

  return new;
end $$;


-- ---------------------------------------------------------------------------
-- 2. CÓDIGOS DE ISENÇÃO DA AT
--
-- Lista fechada. `usa_em_saude` distingue os que interessam a uma clínica dos
-- que não, para o ecrã poder mostrar primeiro o que faz sentido — sem esconder
-- os outros, porque um dia alguém fatura algo fora do comum.
-- ---------------------------------------------------------------------------
create table if not exists public.codigos_isencao_iva (
  codigo        text primary key,
  descricao     text not null,
  base_legal    text,
  usa_em_saude  boolean not null default false,
  ordem         smallint not null default 100,
  created_at    timestamptz not null default now()
);

comment on table public.codigos_isencao_iva is
  'Codigos de motivo de isencao da AT. Lista fechada para o ecra nao aceitar um codigo errado. Saude = M07 (art. 9.o do CIVA), NAO M01/M02.';

insert into public.codigos_isencao_iva (codigo, descricao, base_legal, usa_em_saude, ordem) values
  ('M07', 'Isento de IVA — artigo 9.º do CIVA (profissões médicas e paramédicas, clínicas e estabelecimentos similares)',
   'CIVA, artigo 9.º', true, 10),
  ('M10', 'Isento de IVA — regime especial de isenção (artigo 53.º do CIVA)', 'CIVA, artigo 53.º', true, 20),
  ('M11', 'Isento de IVA — regime dos pequenos retalhistas', 'CIVA, artigo 60.º', false, 30),
  ('M01', 'Quantias pagas em nome e por conta do adquirente', 'CIVA, artigo 16.º, n.º 6', false, 40),
  ('M02', 'Venda de mercadorias a exportador nacional', 'CIVA, artigo 14.º', false, 50),
  ('M05', 'Isento de IVA — operações triangulares', 'CIVA, artigo 16.º, n.º 2', false, 60),
  ('M06', 'Isento de IVA — transmissões de bens e prestações de serviços não sujeitas', 'CIVA, artigo 4.º', false, 70),
  ('M08', 'Isento de IVA — outras isenções', 'CIVA, artigo 12.º', false, 80),
  ('M09', 'Isento de IVA — regimes especiais', 'CIVA, artigo 12.º', false, 90),
  ('M13', 'Isento de IVA — operações à margem', 'CIVA, artigo 12.º', false, 100),
  ('M14', 'Isento de IVA — operações com gás natural', 'CIVA, artigo 12.º', false, 110),
  ('M15', 'Isento de IVA — operações com energia elétrica', 'CIVA, artigo 12.º', false, 120),
  ('M16', 'Isento de IVA — operações com gases de petróleo', 'CIVA, artigo 12.º', false, 130),
  ('M20', 'Isento de IVA — operações de seguro', 'CIVA, artigo 12.º', false, 140),
  ('M21', 'Isento de IVA — operações financeiras', 'CIVA, artigo 12.º', false, 150),
  ('M99', 'Não sujeito / outro motivo não tipificado — exige menção escrita', 'Regime geral', false, 200)
on conflict (codigo) do update
   set descricao    = excluded.descricao,
       base_legal   = excluded.base_legal,
       usa_em_saude = excluded.usa_em_saude,
       ordem        = excluded.ordem;

alter table public.codigos_isencao_iva enable row level security;
grant select on public.codigos_isencao_iva to authenticated;
grant all on public.codigos_isencao_iva to service_role;

drop policy if exists codigos_isencao_select on public.codigos_isencao_iva;
create policy codigos_isencao_select on public.codigos_isencao_iva
  for select to authenticated using (true);


-- ---------------------------------------------------------------------------
-- 3. PASSAR UM RASCUNHO A DOCUMENTO
--
-- A única forma de emitir. Faz três coisas que não podem ser separadas:
--
--   a) exige que o documento seja rascunho — não se "reemite" o que já saiu;
--   b) exige assinatura — recusa antes do CHECK, com mensagem útil;
--   c) exige que o documento tenha linhas — uma fatura de zero euros sem nada
--      dentro é um número da série consumido por nada.
--
-- A assinatura é um PARÂMETRO e não vem do documento: quem assina é o servidor,
-- a partir do conteúdo persistido, e o valor entra aqui já pronto. O cliente
-- nunca calcula nem escolhe este valor.
-- ---------------------------------------------------------------------------
create or replace function clinia.emitir_fatura(
  p_documento_id uuid,
  p_assinatura   text
)
returns public.documentos_fiscais
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
declare
  v_doc      public.documentos_fiscais%rowtype;
  v_linhas   int;
  v_clinica  uuid;
begin
  v_clinica := clinia.current_clinica_id();

  if v_clinica is null then
    raise exception 'Sem clinica associada ao utilizador.' using errcode = 'insufficient_privilege';
  end if;

  /* Quem emite tem de poder escrever na faturacao. A gestao ve e confere, mas
     nao emite: emitir tem consequencias legais. */
  if not clinia.pode_escrever_ecra('faturacao') then
    raise exception 'O teu perfil nao pode emitir documentos fiscais.'
      using errcode = 'insufficient_privilege',
            hint = 'A faturacao e de leitura para o teu perfil. Pede a um administrador.';
  end if;

  select * into v_doc
    from public.documentos_fiscais d
   where d.id = p_documento_id
     and d.clinica_id = v_clinica
   for update;

  if v_doc.id is null then
    raise exception 'Documento nao encontrado.' using errcode = 'no_data_found';
  end if;

  if v_doc.estado <> 'rascunho' then
    raise exception
      'O documento % ja foi emitido e nao se reemite. Para corrigir, emite uma nota de credito.',
      coalesce(v_doc.numero::text, v_doc.id::text)
      using errcode = 'check_violation';
  end if;

  select count(*) into v_linhas
    from public.linhas_documento l where l.documento_id = p_documento_id;

  if v_linhas = 0 then
    raise exception 'Um documento sem linhas nao se emite.'
      using errcode = 'check_violation',
            hint = 'Acrescenta pelo menos uma linha com o que foi prestado.';
  end if;

  if coalesce(p_assinatura, '') = '' then
    raise exception
      'Falta a assinatura. A assinatura e produzida pela chave privada da clinica, numa funcao de servidor.'
      using errcode = 'not_null_violation',
            hint = 'O servico de assinatura ainda nao esta disponivel. O documento fica em rascunho.';
  end if;

  /* O UPDATE ativa os gatilhos: `proteger_documento_fiscal` valida a transicao,
     `validar_hash_documento` verifica a assinatura e `emitir_documento_fiscal`
     atribui numero, ano, serie, ATCUD e congela os dados do emitente. Fazer
     isto com um UPDATE, e nao com um INSERT de um documento completo, e o que
     permite separar preparar de emitir. */
  update public.documentos_fiscais
     set estado = 'emitido',
         hash   = p_assinatura
   where id = p_documento_id
  returning * into v_doc;

  return v_doc;
end $$;

comment on function clinia.emitir_fatura(uuid, text) is
  'Passa um rascunho a documento fiscal numerado. Exige assinatura e pelo menos uma linha. Unica via de emissao.';

grant execute on function clinia.emitir_fatura(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3b. A ASSINATURA PODE ENTRAR NA EMISSÃO — E SÓ AÍ
--
-- O gatilho `proteger_documento_fiscal` recusa alterar a assinatura de um
-- documento emitido, e faz bem: é o que impede falsificar quem assinou. Mas
-- `hash` também estava fora da lista de campos mutáveis, e isso tornava
-- impossível a transição rascunho → emitido por UPDATE: a assinatura tem de
-- entrar exatamente nesse momento.
--
-- A porta abre-se do tamanho mínimo: `hash` só pode mudar quando o documento
-- SAI de 'rascunho'. A partir do momento em que é um documento, a assinatura
-- volta a ser intocável — que é o que a migração 0015 garantiu e esta não pode
-- desfazer.
--
-- NOTA para quem for ler isto mais tarde: o desenho previsto é a assinatura ser
-- feita por uma Edge Function, com a chave privada num cofre, e não aqui. Esta
-- função existe para que o fluxo esteja completo e testado; quem assina a sério
-- é o servidor, e o cliente nunca calcula nem escolhe este valor.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_documento_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
declare
  v_permitidos text[] := array[
    'estado','motivo_anulacao','pago_em','pago_valor',
    'documento_url','documento_hash_ficheiro','updated_at'
  ];
  v_campo text;
  /* A assinatura só pode entrar na passagem de rascunho a documento. */
  v_a_emitir boolean := (tg_op = 'UPDATE' and old.estado = 'rascunho' and new.estado <> 'rascunho');
begin
  if tg_op = 'DELETE' then
    raise exception
      'Documentos fiscais não se apagam (%). Anula-se com uma nota de crédito.', old.numero
      using errcode = 'check_violation',
            hint = 'Emite uma nota de crédito com o motivo da anulação.';
  end if;

  -- Rascunho é livre: ainda não é documento.
  if old.estado = 'rascunho' and new.estado = 'rascunho' then
    return new;
  end if;

  for v_campo in
    select key from jsonb_each(to_jsonb(new)) n
     where n.value is distinct from (to_jsonb(old) -> n.key)
  loop
    /* Na emissão de um rascunho, os campos que a numeração preenche (número,
       ano, série, ATCUD, QR, emitente, data de emissão, hash controlo) e a
       assinatura entram todos de uma vez. São exatamente os campos que o
       gatilho `t_documentos_emitir` escreve — e são legítimos precisamente
       porque o documento ESTÁ a ser emitido.

       A assinatura continua a não poder mudar depois: fora desta transição,
       `hash` não está na lista e o gatilho recusa. É o que a migração 0015
       garantiu, e esta não o desfaz. */
    if v_a_emitir and v_campo = any (array[
         'hash','numero','ano','serie_codigo','atcud','qrcode_url','string_assinada',
         'emitente_nif','emitente_nome','emitente_morada','data_emissao','emitido_em',
         'hash_controlo'
       ])
    then
      continue;
    end if;

    if not (v_campo = any (v_permitidos)) then
      raise exception
        'Documento fiscal emitido não pode ser alterado (campo "%"). Emite uma nota de crédito.', v_campo
        using errcode = 'check_violation';
    end if;
  end loop;

  return new;
end $$;

comment on function clinia.proteger_documento_fiscal() is
  'Imutabilidade de documentos fiscais. Na transicao de rascunho para emitido deixam entrar os campos da numeracao e a assinatura; fora disso a assinatura e intocavel.';


-- ---------------------------------------------------------------------------
-- 3c. A NUMERAÇÃO TEM DE CORRER TAMBÉM NO UPDATE
--
-- `t_documentos_emitir` estava definido só para `before insert`. Enquanto a
-- única forma de criar um documento era inseri-lo já completo, isso bastava.
-- Com a separação entre preparar e emitir, a emissão é um UPDATE — e o gatilho
-- não corria. O erro que aparecia era este:
--
--     new row for relation "documentos_fiscais" violates check constraint
--     "documentos_emitido_completo"
--
-- que não diz nada sobre a causa (a numeração não aconteceu) e obriga a ir ler
-- o gatilho para perceber.
--
-- O gatilho é, ele próprio, seguro para UPDATE: a primeira coisa que faz é
-- `if new.numero is not null then return new;` — um documento já numerado não
-- volta a ser numerado, e o contador da série nunca anda para trás.
-- ---------------------------------------------------------------------------
drop trigger if exists t_documentos_emitir on public.documentos_fiscais;
create trigger t_documentos_emitir
  before insert or update on public.documentos_fiscais
  for each row execute function clinia.emitir_documento_fiscal();


-- ---------------------------------------------------------------------------
-- 4. ANULAR COM NOTA DE CRÉDITO
--
-- Uma fatura com erro NÃO se apaga nem se edita: emite-se uma nota de crédito
-- que a referencia, com o motivo escrito. É o que a lei pede e é o que o gatilho
-- de imutabilidade impõe.
--
-- A função faz as três partes numa transação: cria a nota, copia as linhas com
-- os valores negativos, e marca o documento original como anulado. Se alguma
-- falhar, não fica nada a meio — e uma fatura meio-anulada é pior do que uma
-- fatura errada.
-- ---------------------------------------------------------------------------
create or replace function clinia.anular_documento(
  p_documento_id uuid,
  p_motivo       text,
  p_serie_id     uuid
)
returns public.documentos_fiscais
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
declare
  v_orig   public.documentos_fiscais%rowtype;
  v_nota   public.documentos_fiscais%rowtype;
  v_clinica uuid;
  v_linhas int;
begin
  v_clinica := clinia.current_clinica_id();

  if v_clinica is null then
    raise exception 'Sem clinica associada ao utilizador.' using errcode = 'insufficient_privilege';
  end if;

  if not clinia.pode_escrever_ecra('faturacao') then
    raise exception 'O teu perfil nao pode anular documentos fiscais.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Uma anulacao tem de dizer porque. O motivo e obrigatorio.'
      using errcode = 'check_violation';
  end if;

  select * into v_orig
    from public.documentos_fiscais d
   where d.id = p_documento_id and d.clinica_id = v_clinica
   for update;

  if v_orig.id is null then
    raise exception 'Documento nao encontrado.' using errcode = 'no_data_found';
  end if;

  if v_orig.estado = 'rascunho' then
    raise exception 'Um rascunho nao se anula: apaga-se. Ainda nao e documento.'
      using errcode = 'check_violation';
  end if;

  if v_orig.estado = 'anulado' then
    raise exception 'O documento % ja esta anulado.', v_orig.numero
      using errcode = 'check_violation';
  end if;

  /* Uma nota de crédito por documento: duas notas para a mesma fatura é um
     erro de quem opera, e deixaria o SAF-T com um saldo que não fecha. */
  if exists (select 1 from public.documentos_fiscais n
              where n.documento_origem_id = p_documento_id
                and n.tipo = 'nota_credito') then
    raise exception 'O documento % ja tem uma nota de credito.', v_orig.numero
      using errcode = 'check_violation';
  end if;

  /* A nota nasce como rascunho para poder ser assinada.
   *
   * OS VALORES SÃO POSITIVOS, e isso não é um detalhe: há um CHECK na tabela
   * (`documentos_totais_nao_negativos`) que recusa valores negativos, e está
   * certo. Uma nota de crédito não é "uma fatura de valor negativo" — é um
   * documento com os seus próprios valores, que o SAF-T declara como crédito e
   * cujo sinal se determina pelo TIPO (`nota_credito`), não pelo número.
   *
   * Guardar -50 numa coluna de total faria a soma dos documentos de uma série
   * dar um valor que não corresponde a nada, e o resumo de IVA deixaria de
   * fechar. A simetria é do SIGNIFICADO do documento, não do sinal do número. */
  insert into public.documentos_fiscais (
    clinica_id, serie_id, tipo, estado, adquirente_utente_id, adquirente_nome,
    adquirente_nif, adquirente_morada, pagador, seguradora, numero_apolice,
    total_iliquido, total_iva, total_descontos, total_documento,
    documento_origem_id, motivo_anulacao, observacoes, utente_id, episodio_id
  ) values (
    v_clinica, p_serie_id, 'nota_credito', 'rascunho',
    v_orig.adquirente_utente_id, v_orig.adquirente_nome, v_orig.adquirente_nif,
    v_orig.adquirente_morada, v_orig.pagador, v_orig.seguradora, v_orig.numero_apolice,
    v_orig.total_iliquido, v_orig.total_iva, v_orig.total_descontos, v_orig.total_documento,
    p_documento_id, btrim(p_motivo),
    'Nota de credito do documento ' || coalesce(v_orig.serie_codigo, '') || '/' || coalesce(v_orig.numero::text, ''),
    v_orig.utente_id, v_orig.episodio_id
  ) returning * into v_nota;

  select count(*) into v_linhas from public.linhas_documento l where l.documento_id = p_documento_id;

  if v_linhas > 0 then
    insert into public.linhas_documento (
      clinica_id, documento_id, ordem, item_id, codigo, descricao, quantidade,
      unidade, preco_unitario, desconto_percentagem, desconto_valor,
      taxa_iva, codigo_isencao, mencao_isencao, base_incidencia, valor_iva,
      total_linha, ato_id, profissional_id, data_prestacao
    )
    select l.clinica_id, v_nota.id, l.ordem, l.item_id, l.codigo,
           'Anulacao: ' || l.descricao, l.quantidade, l.unidade, l.preco_unitario,
           l.desconto_percentagem, l.desconto_valor, l.taxa_iva,
           l.codigo_isencao, l.mencao_isencao,
           l.base_incidencia, l.valor_iva, l.total_linha,
           l.ato_id, l.profissional_id, l.data_prestacao
      from public.linhas_documento l
     where l.documento_id = p_documento_id;
  end if;

  /* O original passa a anulado. `motivo_anulacao` e `estado` estao na lista de
     campos mutaveis do gatilho de protecao — de propósito: e a unica coisa que
     se pode mudar num documento emitido. */
  update public.documentos_fiscais
     set estado = 'anulado',
         motivo_anulacao = btrim(p_motivo)
   where id = p_documento_id;

  return v_nota;
end $$;

comment on function clinia.anular_documento(uuid, text, uuid) is
  'Anula um documento emitido criando a nota de credito que o referencia. Nao apaga nem edita: e o que a lei exige.';

grant execute on function clinia.anular_documento(uuid, text, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. CATÁLOGO DE ATOS FATURÁVEIS
--
-- Sem isto, a primeira fatura de uma clínica obrigava a inventar o catálogo de
-- preços todo de uma vez. Uma clínica de reabilitação tem meia dúzia de atos
-- que faz todos os dias.
--
-- As isenções de saúde em Portugal cabem no artigo 9.º do CIVA, e a menção que
-- sai impressa tem de nomear o artigo. Os preços são ZERO de propósito: um preço
-- inventado por nós seria um erro de faturação à espera de acontecer. O
-- administrador põe os dele.
-- ---------------------------------------------------------------------------
insert into public.itens_faturaveis
  (clinica_id, codigo, designacao, descricao, ato_tipo, especialidade,
   preco, unidade, taxa_iva, codigo_isencao, mencao_isencao, ativo)
values
  (null, 'CONS_MFR', 'Consulta de Medicina Física e de Reabilitação',
   'Primeira consulta ou consulta subsequente de fisiatria.', 'consulta', 'mfr',
   0, 'consulta', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_FISIO', 'Tratamento de fisioterapia',
   'Sessão de fisioterapia, individual.', 'sessao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_FISIO_GRUPO', 'Tratamento de fisioterapia em grupo',
   'Sessão de fisioterapia em grupo.', 'sessao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_MFR', 'Tratamento de medicina física e de reabilitação',
   'Sessão de MFR prescrita por fisiatra.', 'sessao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_OSTEO', 'Consulta de osteopatia',
   'Sessão de osteopatia. ATENCAO: a isencao do artigo 9.o depende do exercicio de profissoes de saude reguladas — confirmar com o contabilista antes de faturar isento.',
   'sessao', 'osteopatia',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_TO', 'Sessão de terapia ocupacional',
   'Sessão de terapia ocupacional.', 'sessao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'TRAT_TF', 'Sessão de terapia da fala',
   'Sessão de terapia da fala.', 'sessao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'AVAL_FUNC', 'Avaliação funcional',
   'Avaliação inicial com medições e definição de objetivos.', 'avaliacao', 'mfr',
   0, 'sessao', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'MCDT_EMG', 'Estudo neurofisiológico (EMG/ENMG)',
   'Eletromiografia ou estudo de condução nervosa.', 'procedimento', 'mfr',
   0, 'unidade', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'AJUDA_TECNICA', 'Fornecimento de ajuda técnica',
   'Dispositivo ou produto de apoio. ATENCAO: o fornecimento de material pode nao beneficiar da isencao do artigo 9.o — confirmar e, se for o caso, aplicar a taxa normal numa linha separada.',
   'procedimento', null,
   0, 'unidade', 23, null, null, true),

  (null, 'RELATORIO', 'Relatório clínico para seguradora ou junta médica',
   'Elaboração de relatório a pedido de terceiro.', 'nota_clinica', null,
   0, 'unidade', 0, 'M07', 'Isento de IVA ao abrigo do artigo 9.º, n.º 1 do CIVA', true),

  (null, 'MATERIAL', 'Venda de material',
   'Venda de material ao utente (ortóteses, meias de compressão, etc.). NAO isento.',
   'procedimento', null,
   0, 'unidade', 23, null, null, true)
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 6. VERIFICAÇÃO
-- ---------------------------------------------------------------------------
do $$
declare
  v_itens   int;
  v_codigos int;
  v_m07     boolean;
begin
  select count(*) into v_itens   from public.itens_faturaveis where clinica_id is null;
  select count(*) into v_codigos from public.codigos_isencao_iva;

  if v_itens = 0 then
    raise exception 'O catalogo de atos faturaveis ficou vazio: a primeira fatura obrigaria a inventar precos todos de uma vez.';
  end if;

  select exists (select 1 from public.codigos_isencao_iva where codigo = 'M07')
    into v_m07;

  if not v_m07 then
    raise exception 'Falta o codigo M07 (isencoes do artigo 9.o do CIVA) — e o que se aplica a saude.';
  end if;

  /* Os tres itens que uma clinica de reabilitacao fatura todos os dias tem de
     ter isencao configurada, senao o CHECK da tabela recusa a primeira fatura
     e o erro aparece longe da causa. */
  if exists (
    select 1 from public.itens_faturaveis
     where clinica_id is null and taxa_iva = 0
       and (codigo_isencao is null or mencao_isencao is null)
  ) then
    raise exception 'Ha itens com taxa 0 e sem isencao configurada: a primeira fatura seria recusada pela base de dados.';
  end if;

  raise notice 'Faturacao: % atos no catalogo e % codigos de isencao (saude = M07).', v_itens, v_codigos;
end $$;


-- ----------------------------------------------------------------------------
-- 0019_visibilidade_so_admin.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0019 — Configurar a visibilidade exige administrador
--
-- O BURACO
-- ============================================================================
-- A migração 0014 criou as políticas de escrita das tabelas da faturação
-- percorrendo uma lista:
--
--     por_clinica text[] := array[
--       'perfil_visibilidade','clinica_fiscal','itens_faturaveis',
--       'precos_convencao','series_documentos','documentos_fiscais',
--       'linhas_documento','pagamentos'
--     ];
--
-- e deu a TODAS a mesma política: «pode escrever quem pode escrever no ecrã de
-- faturação».
--
-- Para as tabelas de faturação, está certo. Para `perfil_visibilidade`, é um
-- erro grave: a tabela que decide QUEM VÊ O QUÊ ficou a poder ser alterada por
-- quem tem acesso à faturação. Ou seja, um utilizador com esse acesso podia
-- conceder-se, por um pedido HTTP direto, todos os ecrãs que quisesse —
-- incluindo os clínicos.
--
-- O atalho de `e_admin()` dentro de `ve_ecra` não é afetado (é do administrador),
-- mas `perfil_visibilidade` é a tabela onde a permissão é ESCRITA. Deixá-la
-- aberta é deixar a fechadura ao lado da porta.
--
-- O mesmo raciocínio para `ecras`: o catálogo não devia ser editável por quem
-- não administra, e a política de lá é `e_admin()` — correta.
--
-- A CORREÇÃO, EM DUAS CAMADAS
-- ============================================================================
--   1. Uma política nova, restrita ao administrador, a substituir a genérica.
--   2. Um gatilho, porque a política sozinha não chega: o PostgreSQL combina as
--      políticas permissivas com OU. Se uma política mais larga continuar a
--      existir (por exemplo, criada por outra migração), a estreita deixa de
--      proteger. O gatilho não depende de nenhuma política.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. PERMISSÃO DE EXECUÇÃO NAS FUNÇÕES DE CONTEXTO
--
-- `clinia.e_gestor()` foi criada na migração 0017. A migração 0010 concede
-- `execute` a `authenticated` com um `grant ... on all functions in schema
-- clinia`, que correu MUITO antes — e por isso não a apanhou.
--
-- Consequência medida: `select clinia.e_gestor()` como `authenticated` devolve
-- «permission denied for function e_gestor». E como a vista `vw_meu_contexto` a
-- chama, a vista passou a falhar para todos os utilizadores — o que quebra o
-- arranque da aplicação inteira, e não só a visibilidade.
--
-- `grant ... on all functions` é uma armadilha: só apanha o que existe no
-- momento em que corre. Uma função nova tem de se conceder sozinha, e é o que
-- este bloco faz — de forma explícita, para se poder verificar.
-- ---------------------------------------------------------------------------
grant execute on function clinia.e_gestor() to authenticated;
grant execute on function clinia.e_admin() to authenticated;
grant execute on function clinia.e_clinico() to authenticated;
grant execute on function clinia.current_clinica_id() to authenticated;
grant execute on function clinia.current_perfil() to authenticated;
grant execute on function clinia.ve_ecra(text) to authenticated;
grant execute on function clinia.pode_escrever_ecra(text) to authenticated;
grant execute on function clinia.emitir_fatura(uuid, text) to authenticated;
grant execute on function clinia.anular_documento(uuid, text, uuid) to authenticated;
grant execute on function clinia.modulo_ativo(uuid, text) to authenticated;
grant execute on function clinia.meus_modulos() to authenticated;

/* `auth.uid()` também. É a função que diz QUEM está a pedir, e sem permissão de
   execução qualquer função ou vista que a chame falha com «permission denied
   for schema auth» — um erro que não aponta para a causa e que, em ambiente de
   desenvolvimento, é fácil de não ver.
   
   O Supabase concede-a por omissão no projeto a sério; este ficheiro não pode
   depender disso, porque também corre em testes contra PostgreSQL limpo. */
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;


-- ---------------------------------------------------------------------------
-- 1. A política de escrita de `perfil_visibilidade` passa a ser do administrador
-- ---------------------------------------------------------------------------=


-- ---------------------------------------------------------------------------
-- 1. A política de escrita de `perfil_visibilidade` passa a ser do administrador
-- ---------------------------------------------------------------------------
drop policy if exists perfil_visibilidade_write on public.perfil_visibilidade;
drop policy if exists perfil_visibilidade_admin on public.perfil_visibilidade;

create policy perfil_visibilidade_admin on public.perfil_visibilidade
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_admin())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_admin());

comment on policy perfil_visibilidade_admin on public.perfil_visibilidade is
  'Configurar a visibilidade por perfil e so do administrador. Quem escreve na faturacao NAO pode alterar as suas proprias permissoes.';


-- ---------------------------------------------------------------------------
-- 2. O gatilho, que não depende de nenhuma política
--
-- Porque não basta a política: as políticas permissivas somam-se com OU. Basta
-- alguém acrescentar, numa migração futura, uma política mais larga para esta
-- tabela para a restrição deixar de existir — em silêncio, e sem que nada falhe.
--
-- O gatilho corre antes de a linha ser escrita e não tem como ser contornado
-- por uma política. É a camada que garante a regra mesmo que a lista de
-- políticas se estrague outra vez.
-- ---------------------------------------------------------------------------
create or replace function clinia.proteger_visibilidade()
returns trigger
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
begin
  /* ESTE GATILHO SÓ JULGA UTILIZADORES DA APLICAÇÃO.
   *
   * A regra «só o administrador configura a visibilidade» é sobre QUEM PEDE, não
   * sobre quem escreve a linha. Há dois casos em que não há um utilizador a
   * pedir, e nenhum deles é um ataque:
   *
   *   · `auth.uid()` nulo — migrações, seeds e bootstrap correm sem sessão;
   *   · `service_role` — o papel de administração do Supabase, que já pode
   *     tudo, incluindo `bypassrls`.
   *
   * E há um terceiro, que foi o que obrigou a escrever isto com cuidado: o
   * gatilho `semear_visibilidade_da_clinica()` da migração 0006, que dá a
   * visibilidade POR OMISSÃO a uma clínica nova. Não é um utilizador a pedir
   * nada — é o sistema a preparar uma clínica. Se o gatilho o julgasse como se
   * fosse um pedido, criar uma clínica falharia.
   *
   * O que garante que isto não é um atalho para um atacante é o RLS, que corre
   * ANTES do gatilho: para chegar aqui como `authenticated`, a política
   * `perfil_visibilidade_admin` já teve de deixar passar — e essa exige
   * administrador. Este gatilho é a segunda camada, para o caso de as políticas
   * se estragarem; não é a primeira. */
  if auth.uid() is null
     or coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
  then
    return coalesce(new, old);
  end if;

  /* Clínica a nascer, ou visibilidade a ser semeada em bloco.
   *
   * Não se deteta isto adivinhando pelo estado da tabela: quem semeia DIZ que
   * está a semear, com um sinalizador de transação. Adivinhar — «esta clínica
   * ainda não tem atribuições, logo é nova» — funciona até ao dia em que um
   * administrador apaga a última atribuição de uma clínica existente e passa a
   * poder inserir sem ser julgado.
   *
   * O sinalizador é local à transação (`set_config(..., true)`), por isso não
   * escapa para o pedido seguinte. Quem o põe é
   * `clinia.semear_visibilidade_da_clinica()`, que é `security definer` e só
   * corre no `after insert` de `clinicas`, e o próprio seed. */
  if coalesce(current_setting('clinia.a_semear_visibilidade', true), '') = 'sim' then
    return coalesce(new, old);
  end if;

  if not clinia.e_admin() then
    raise exception
      'Só o administrador da clínica pode alterar a visibilidade dos ecrãs.'
      using errcode = 'insufficient_privilege',
            hint = 'A visibilidade decide quem vê o processo clínico. Não é uma preferência de utilizador.';
  end if;

  return coalesce(new, old);
end $$;

comment on function clinia.proteger_visibilidade() is
  'Impede que quem nao e administrador altere a visibilidade por perfil. Segunda camada, independente das politicas de RLS.';

drop trigger if exists t_perfil_visibilidade_proteger on public.perfil_visibilidade;
create trigger t_perfil_visibilidade_proteger
  before insert or update or delete on public.perfil_visibilidade
  for each row execute function clinia.proteger_visibilidade();


-- ---------------------------------------------------------------------------
-- 2b. O SEMEADOR DIZ QUE ESTÁ A SEMEAR
--
-- `clinia.semear_visibilidade_da_clinica()` (migração 0006) é chamado pelo
-- gatilho `after insert` de `clinicas`, e é ele que dá a visibilidade por
-- omissão a uma clínica nova. Não é um utilizador a pedir nada — é o sistema a
-- preparar uma clínica — mas o gatilho acima julgá-lo-ia como se fosse um
-- pedido, e criar uma clínica falharia.
--
-- A função passa a levantar o sinalizador antes de escrever, e a repô-lo no
-- fim. Assim a porta fica aberta exatamente enquanto dura o semeio, dentro da
-- mesma transação. */
create or replace function clinia.semear_visibilidade_da_clinica()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perfis_todos text[] := array[
    'administrador','fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
    'terapeuta_da_fala','psicologo','enfermeiro','rececao','gestao'
  ];
  v_ecra record;
  v_perfil text;
begin
  perform set_config('clinia.a_semear_visibilidade', 'sim', true);

  for v_ecra in select * from public.ecras where ativo and codigo <> 'portal' loop
    foreach v_perfil in array v_perfis_todos loop
      if v_perfil = any (v_ecra.visivel_em::text[]) then
        insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
        values (
          new.id, v_perfil::public.perfil_tipo, v_ecra.id, true,
          (v_perfil = 'gestao' and v_ecra.area = 'faturacao')
          or (v_perfil = 'rececao' and v_ecra.area = 'clinica')
        )
        on conflict (clinica_id, perfil, ecra_id) do nothing;
      end if;
    end loop;
  end loop;

  insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
  select new.id, 'utente'::public.perfil_tipo, e.id, true, true
    from public.ecras e where e.codigo = 'portal'
  on conflict (clinica_id, perfil, ecra_id) do nothing;

  perform set_config('clinia.a_semear_visibilidade', 'nao', true);

  return new;
end $$;


-- ---------------------------------------------------------------------------
-- 3. O catálogo de ecrãs também é do administrador
--
-- A política já o era, mas a lista da 0014 dava escrita genérica às tabelas por
-- clínica — e `ecras` não está nessa lista. Confirma-se e reforça-se, porque
-- uma migração futura que acrescente `ecras` à lista reabriria o buraco.
-- ---------------------------------------------------------------------------
drop policy if exists ecras_write on public.ecras;
create policy ecras_write on public.ecras
  for all to authenticated
  using (clinia.e_admin())
  with check (clinia.e_admin());


-- ---------------------------------------------------------------------------
-- 4. Verificação
--
-- Pergunta ao CATÁLOGO quais são as políticas de escrita desta tabela e falha
-- se alguma não exigir o administrador. É a única forma de apanhar uma política
-- mais larga acrescentada noutro sítio — que é exatamente o defeito que esta
-- migração corrige.
--
-- Percorre TODAS as políticas e decide em PL/pgSQL, em vez de filtrar por
-- `polcmd` no SQL. `polcmd` é um "char" e compará-lo com literais é frágil
-- entre versões: uma condição que não corresponde a nada devolve zero linhas, e
-- uma verificação que devolve zero linhas passa sempre. Um teste que não testa
-- é pior do que nenhum, porque dá confiança.
-- ---------------------------------------------------------------------------
do $$
declare
  p         record;
  v_escrita int := 0;
  v_largas  text[] := '{}';
begin
  for p in
    select polname,
           polcmd::text as cmd,
           coalesce(pg_get_expr(polqual, polrelid), '')      as usando,
           coalesce(pg_get_expr(polwithcheck, polrelid), '') as verificando
      from pg_policy
     where polrelid = 'public.perfil_visibilidade'::regclass
  loop
    /* 'r' = select. Só interessam as políticas que permitem escrever. */
    if p.cmd <> 'r' then
      v_escrita := v_escrita + 1;

      if position('e_admin' in p.usando) = 0
         and position('e_admin' in p.verificando) = 0
      then
        v_largas := v_largas || p.polname;
      end if;
    end if;
  end loop;

  if v_escrita = 0 then
    raise exception 'perfil_visibilidade ficou SEM politica de escrita: ninguem consegue configurar a visibilidade.';
  end if;

  if array_length(v_largas, 1) > 0 then
    raise exception
      'Politicas de escrita em perfil_visibilidade que NAO exigem administrador: %. A visibilidade podia ser alterada por quem nao a devia alterar.',
      array_to_string(v_largas, ', ');
  end if;

  raise notice 'Visibilidade: % politica(s) de escrita, todas restritas ao administrador.', v_escrita;
end $$;


-- ----------------------------------------------------------------------------
-- 0020_especialidade_e_mcid.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0020 — ESQUEMA: especialidade não obrigatória e MCID
--
-- SÓ ESQUEMA. Os dados — o MCID das escalas existentes e os quatro PROMs — vão
-- no seed 0007, e a separação não é arrumação: as migrações correm ANTES dos
-- seeds, e as escalas da EVA, NPRS e Barthel são criadas pelo seed 0002. A
-- primeira versão disto estava toda numa migração e os `update` não alteravam
-- nada, porque as escalas ainda não existiam. A verificação apanhou-o.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. A ESPECIALIDADE DEIXA DE SER OBRIGATÓRIA PARA QUEM NÃO TRATA
--
-- `perfis.especialidade` era NOT NULL, e por isso a receção e a gestão eram
-- obrigadas a declarar uma especialidade CLÍNICA que não têm. A especialidade
-- diz o que a PESSOA é; um rececionista não é nada daquilo.
--
-- O efeito prático era pior do que parece: qualquer contagem por especialidade
-- passava a incluir administrativos, e uma clínica com três rececionistas
-- aparecia com três profissionais de MFR.
--
-- A regra passa a ser: quem exerce clínica tem especialidade; quem não exerce,
-- não tem. E fica um CHECK a garanti-lo — uma regra que não é imposta é uma
-- regra que se perde na alteração seguinte.
-- ---------------------------------------------------------------------------
alter table public.perfis alter column especialidade drop not null;

comment on column public.perfis.especialidade is
  'Especialidade de quem exerce clinica. NULO para perfis administrativos (recepcao, gestao): a especialidade diz o que a pessoa e, e um rececionista nao tem uma.';

/* Os perfis que EXERCEM clínica têm de ter especialidade. O `administrador`
   fica de fora de propósito: é o dono da clínica e pode não ser clínico — numa
   clínica pequena é frequentemente o próprio fisioterapeuta, mas não é sempre,
   e obrigá-lo seria inventar um dado. */
alter table public.perfis drop constraint if exists perfis_especialidade_coerente;
alter table public.perfis add constraint perfis_especialidade_coerente
  check (
    perfil not in ('fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
                   'terapeuta_da_fala','psicologo','enfermeiro')
    or especialidade is not null
  );

/* Corrigir o que ficou errado: os perfis administrativos que foram obrigados a
   declarar uma especialidade passam a nulo. Sem isto, a coluna passa a aceitar
   nulos mas os dados continuam a mentir. */
update public.perfis
   set especialidade = null
 where perfil in ('rececao','gestao')
   and especialidade is not null;


-- ---------------------------------------------------------------------------
-- 1b. E O MESMO NO DIRETÓRIO DE PROFISSIONAIS
--
-- `public.profissionais` é o diretório de quem exerce, e é espelhado a partir de
-- `perfis` por um gatilho. Tinha a mesma restrição NOT NULL — e por isso a
-- alteração acima não chegava: assim que o gatilho espelhasse um perfil de
-- receção, a inserção em `profissionais` falhava com «null value in column
-- especialidade». O perfil era corrigido num sítio e recusado no outro.
--
-- A descoberta foi feita pelo teste, e é o género de defeito que não aparece a
-- ler o código: as duas tabelas parecem independentes e estão ligadas por um
-- gatilho que não se vê na definição de nenhuma delas.
-- ---------------------------------------------------------------------------
alter table public.profissionais alter column especialidade drop not null;

comment on column public.profissionais.especialidade is
  'Especialidade de quem exerce clinica. NULO para pessoal administrativo espelhado de perfis: a especialidade diz o que a pessoa e, e um rececionista nao tem uma.';

alter table public.profissionais drop constraint if exists profissionais_especialidade_coerente;
alter table public.profissionais add constraint profissionais_especialidade_coerente
  check (
    perfil is null
    or perfil not in ('fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
                      'terapeuta_da_fala','psicologo','enfermeiro')
    or especialidade is not null
  );

update public.profissionais
   set especialidade = null
 where perfil in ('rececao','gestao')
   and especialidade is not null;


-- ---------------------------------------------------------------------------
-- 2. MCID — A DIFERENÇA MÍNIMA QUE O DOENTE SENTE
--
-- `mcid` é a menor mudança no score que o doente percebe como melhoria. É o
-- número que separa «melhorou 3 pontos» de «melhorou o suficiente para valer a
-- pena» — e sem ele um número não diz nada a ninguém.
--
-- `mdc` é a Mudança Detetável Mínima: a menor mudança que não é erro de
-- medição. A distinção importa — uma melhoria pode ser sentida pelo doente e
-- ainda estar dentro do ruído do instrumento.
--
-- `mcid_melhoria` e `mcid_pior` são separados onde a literatura os distingue:
-- perder função dói mais do que ganhá-la, e os limiares não são simétricos.
-- ---------------------------------------------------------------------------
alter table public.escalas add column if not exists mcid numeric;
alter table public.escalas add column if not exists mdc numeric;
alter table public.escalas add column if not exists mcid_melhoria numeric;
alter table public.escalas add column if not exists mcid_pior numeric;
alter table public.escalas add column if not exists mcid_fonte text;
alter table public.escalas add column if not exists modo_administracao text not null default 'clinico';
alter table public.escalas add column if not exists periodo_recordacao text;

comment on column public.escalas.mcid is
  'Minimal Clinically Important Difference: a menor mudanca que o doente percebe como melhoria. Sem isto, um numero nao diz se o doente melhorou.';

comment on column public.escalas.modo_administracao is
  'Quem responde: clinico, utente, entrevista ou observacao. Decide se a escala pode ser respondida pelo doente no portal.';

comment on column public.escalas.periodo_recordacao is
  'Janela temporal que a escala pede ao doente (ex.: ultima semana). Sem isto, duas aplicacoes seguidas medem coisas diferentes.';

alter table public.escalas drop constraint if exists escalas_modo_administracao_valido;
alter table public.escalas add constraint escalas_modo_administracao_valido
  check (modo_administracao in ('clinico','utente','entrevista','observacao'));


-- ---------------------------------------------------------------------------
-- 3. VERIFICAÇÃO
--
-- O CHECK da especialidade tem de estar ativo e a coluna tem de aceitar nulos.
-- Uma migração que só escreve `drop not null` sem verificar deixa a regra a
-- depender de a instrução ter corrido.
-- ---------------------------------------------------------------------------
do $$
declare
  v_obrigatoria boolean;
  v_tem_check   boolean;
  v_tem_mcid    boolean;
begin
  select attnotnull into v_obrigatoria
    from pg_attribute
   where attrelid = 'public.perfis'::regclass and attname = 'especialidade';

  if v_obrigatoria then
    raise exception 'perfis.especialidade continua obrigatoria: a rececao continua a ter de inventar uma especialidade clinica.';
  end if;

  select exists (
    select 1 from pg_constraint
     where conrelid = 'public.perfis'::regclass
       and conname = 'perfis_especialidade_coerente'
  ) into v_tem_check;

  if not v_tem_check then
    raise exception 'Falta o CHECK que exige especialidade a quem exerce clinica.';
  end if;

  select exists (
    select 1 from pg_attribute
     where attrelid = 'public.escalas'::regclass and attname = 'mcid' and not attisdropped
  ) into v_tem_mcid;

  if not v_tem_mcid then
    raise exception 'A coluna mcid nao foi criada em escalas.';
  end if;

  raise notice 'Esquema: especialidade deixa de ser obrigatoria a quem nao trata; escalas ganham MCID.';
end $$;


-- ----------------------------------------------------------------------------
-- 0021_motor_de_escalas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0021 — O motor de cálculo das escalas: duas correções
--
-- Esta migração corrige dois defeitos do motor da migração 0006, ambos
-- encontrados ao verificar os quatro instrumentos semeados no seed 0007. Os
-- dois têm a mesma forma: **um número plausível e falso**.
--
-- ============================================================================
-- DEFEITO 1 — UMA ESCALA SEM RESPOSTAS DEVOLVIA ZERO
-- ============================================================================
-- `clinia.calcular_score_escala` terminava assim:
--
--     if v_total > 0 then
--       return v_total;
--     end if;
--     return null;
--
-- A intenção era «sem respostas, sem score». A implementação pergunta se a
-- SOMA é maior do que zero — e uma soma de zero é igual a zero. Consequência:
-- um Barthel com todas as respostas a zero (o doente mais dependente possível)
-- era indistinguível de um Barthel por responder. Os dois devolviam nulo, e o
-- gráfico de evolução mostrava um buraco onde havia o pior resultado possível.
--
-- O Barthel é o caso em que isto mais dói: é a escala que mede a dependência
-- nas atividades básicas, e o valor 0 é clínica e legalmente significativo.
-- Se um doente está acamado e dependente para tudo, o registo tem de o dizer.
--
-- A correção é perguntar pelo NÚMERO DE ITENS RESPONDIDOS, que é o que se
-- queria desde o início:
--
--     if v_conta > 0 then
--       return v_total;
--     end if;
--     return null;
--
-- ============================================================================
-- DEFEITO 2 — NÃO HAVIA FORMA DE ESCREVER UMA FÓRMULA COM SUBTRAÇÃO
-- ============================================================================
-- O motor fazia três coisas: somar os itens (com peso), dividir pelo número de
-- itens (média) ou devolver o valor único. Não havia forma de escrever a
-- expressão do QuickDASH, `(soma/n − 1) × 25`, porque ela subtrai uma constante.
--
-- A primeira tentativa foi aproximar com pesos — e deu 68,75 no mínimo e 343,75
-- no máximo. Uma escala que ninguém reconhece. O teste das extremidades
-- apanhou-o, e a lição é que uma escala com o score errado é pior do que uma
-- escala ausente: produz um número com aparência de válido que vai para um
-- relatório.
--
-- A correção é uma quarta via: `metodo = 'formula'`, com a expressão escrita na
-- própria linha da escala. Isto **abre a porta a dois caminhos para o mesmo
-- número** — que é precisamente o que se quis evitar quando se escreveu o motor
-- — por isso a porta fica estreita de propósito, e a migração verifica que:
--
--   · as escalas de soma simples continuam a usar `soma` e não `formula`;
--   · a expressão não contém um terminador de instrução nem um delimitador de
--     corpo (é código nosso, mas é código que vive numa tabela, e uma tabela é
--     uma coisa que se edita);
--   · a multiplicação tem precedência sobre a soma, e a expressão do QuickDASH
--     é escrita com o parêntese explícito para não depender disso.
--
-- Em SQL, `a / b - 1 * 25` faz a divisão e a multiplicação primeiro. A
-- expressão é substituída textualmente e avaliada, por isso escreve-se com
-- parênteses onde a precedência poderia surpreender.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. A COLUNA DA EXPRESSÃO
-- ---------------------------------------------------------------------------
alter table public.escalas add column if not exists expressao_calculo text;

comment on column public.escalas.expressao_calculo is
  'Expressao SQL do score, avaliada com as variaveis "total" (soma ponderada dos itens) e "n" (numero de itens respondidos). So usada quando metodo = formula. Ex.: QuickDASH: (total / n - 1) * 25';

/* `formula` passa a ser um método válido. O `metodo` é um text com CHECK, e não
   um enum — por isso não é preciso tocar em tipos. */
alter table public.escalas drop constraint if exists escalas_metodo_valido;
alter table public.escalas add constraint escalas_metodo_valido
  check (metodo in ('soma','valor_unico','media','algoritmo','formula'));

/* Uma escala de fórmula sem expressão devolveria nulo em silêncio — que é o
   mesmo defeito do zero, ao contrário. */
alter table public.escalas drop constraint if exists escalas_formula_tem_expressao;
alter table public.escalas add constraint escalas_formula_tem_expressao
  check (metodo <> 'formula' or (expressao_calculo is not null and length(btrim(expressao_calculo)) > 0));


-- ---------------------------------------------------------------------------
-- 2. O MOTOR, CORRIGIDO
--
-- `create or replace` mantém os nomes dos parâmetros (`p_escala`,
-- `p_respostas`) para não partir chamadas existentes — e para não repetir o
-- erro que já se cometeu uma vez neste projeto, em que renomear um parâmetro
-- fez as chamadas falharem com um erro que não apontava para a causa.
-- ---------------------------------------------------------------------------
create or replace function clinia.calcular_score_escala(p_escala uuid, p_respostas jsonb)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $funcao$
declare
  v_metodo     text;
  v_expressao  text;
  v_total      numeric := 0;
  v_conta      integer := 0;
  v_resultado  numeric;
  v_calculo    text;
  v_item       record;
  v_valor      numeric;
begin
  select metodo, expressao_calculo into v_metodo, v_expressao
    from public.escalas where id = p_escala;

  if v_metodo is null then
    return null;
  end if;

  /* Escalas de resposta única (EVA, NPRS): a resposta É o score. */
  if v_metodo = 'valor_unico' then
    return nullif(p_respostas ->> 'valor', '')::numeric;
  end if;

  for v_item in
    select codigo, peso, invertido, min_valor, max_valor
      from public.escala_itens
     where escala_id = p_escala
     order by ordem
  loop
    v_valor := nullif(p_respostas -> v_item.codigo ->> 'valor', '')::numeric;

    /* Item por responder não conta para a soma NEM para o divisor. Contá-lo
       como zero faria a média cair, e um questionário a meio pareceria um
       doente a piorar. */
    continue when v_valor is null;

    if v_item.invertido and v_item.min_valor is not null and v_item.max_valor is not null then
      v_valor := v_item.min_valor + v_item.max_valor - v_valor;
    end if;

    v_total := v_total + (v_valor * coalesce(v_item.peso, 1));
    v_conta := v_conta + 1;
  end loop;

  /* O divisor é o número de itens RESPONDIDOS, e não o número de itens da
     escala. Uma escala a meio tem de dar a média do que foi respondido. */
  if v_conta = 0 then
    return null;
  end if;

  if v_metodo = 'media' then
    return round(v_total / v_conta, 2);
  end if;

  if v_metodo = 'formula' then
    -- A expressão vem da tabela, e uma tabela é uma coisa que se edita — por
    -- isso é validada na escrita (ver o bloco de verificação) e aqui só se
    -- confirma que continua a haver uma. Usam-se comentários de linha e não de
    -- bloco porque um `*/` acidental dentro de um comentário de bloco fecha-o
    -- cedo e o resto do texto passa a ser SQL. Já aconteceu neste ficheiro.
    if v_expressao is null or btrim(v_expressao) = '' then
      return null;
    end if;

    -- A expressão é escrita em termos de `total` (a soma ponderada) e `n` (o
    -- número de itens respondidos).
    --
    -- NÃO CHEGA escrever `execute format('select %s', v_expressao)`: numa
    -- consulta dinâmica, `total` e `n` não são variáveis conhecidas — o SQL
    -- executado é uma consulta nova, sem acesso ao contexto PL/pgSQL. O
    -- resultado era uma exceção em cada chamada e o QuickDASH dava sempre nulo.
    --
    -- O que se faz é SUBSTITUIR os dois nomes pelos valores antes de executar.
    -- A substituição usa `replace` sobre dois literais numéricos, e não
    -- interpolação de texto vindo de fora: `total` e `n` são números calculados
    -- aqui dentro e formatados com `::text`, por isso não há nada que um
    -- utilizador possa escrever que chegue a esta string.
    begin
      v_calculo := replace(
                     replace(v_expressao, 'total', v_total::text),
                     'n', v_conta::text);
      execute format('select %s', v_calculo) into v_resultado;
      return round(v_resultado, 2);
    exception when others then
      -- Uma expressão estragada não pode rebentar a consulta do ecrã clínico
      -- inteiro. Devolve nulo, que é honesto: não se sabe o score.
      return null;
    end;
  end if;

  /* DEFEITO 1, corrigido: perguntar pelos itens respondidos e não pela soma.
     Uma escala com todas as respostas a zero é um resultado clínico — o pior
     possível — e não a ausência de resultado. */
  return v_total;
end;
$funcao$;

comment on function clinia.calcular_score_escala(uuid, jsonb) is
  'Calcula o score a partir das respostas, com o peso de cada item e a expressao da escala. O clinico nao soma a mao (baixa friccao). Devolve nulo SEM RESPOSTAS, e zero quando todas as respostas somam zero.';

grant execute on function clinia.calcular_score_escala(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. O QUICKDASH PASSA A USAR A EXPRESSÃO
--
-- O peso volta a 1: a soma é a soma dos itens, e a fórmula faz o resto. Deixar o
-- peso a 6,25 e aplicar a fórmula contaria a escala duas vezes.
-- ---------------------------------------------------------------------------
update public.escala_itens i set peso = 1
  from public.escalas e
 where i.escala_id = e.id and e.codigo = 'quickdash' and e.clinica_id is null;

update public.escalas
   set metodo = 'formula',
       expressao_calculo = '(total / n - 1) * 25',
       score_min = 0,
       score_max = 100
 where codigo = 'quickdash' and clinica_id is null;


-- ---------------------------------------------------------------------------
-- 4. VERIFICAÇÃO
--
-- Verifica o que se pode verificar sem respostas: que a expressão está lá, que
-- o divisor é o número de itens, e que as escalas de soma simples NÃO passaram
-- a usar fórmula. Os scores calculados são verificados em
-- `db/testes/testar-escalas.mjs`, com respostas a sério.
-- ---------------------------------------------------------------------------
do $$
declare
  v_tipo       text;
  v_obrigatoria boolean;
begin
  /* ESTA VERIFICAÇÃO É DE ESQUEMA, E SÓ DE ESQUEMA.
   *
   * A primeira versão verificava também que existia exatamente uma escala com
   * `metodo = 'formula'` — e falhava sempre, porque as migrações correm ANTES
   * dos seeds e o QuickDASH é criado pelo seed 0007. Uma verificação de dados
   * dentro de uma migração falha por construção, não por defeito.
   *
   * O que se verifica aqui é o que uma migração pode garantir: que o método
   * `formula` passou a ser aceite e que a coluna da expressão existe. Que o
   * QuickDASH a use é verificado pelo teste `db/testes/testar-escalas.mjs`, que
   * corre a instalação inteira.
   */
  select pg_get_constraintdef(oid) into v_tipo
    from pg_constraint
   where conrelid = 'public.escalas'::regclass and conname = 'escalas_metodo_valido';

  if v_tipo is null or position('formula' in v_tipo) = 0 then
    raise exception 'O metodo formula nao ficou aceite em escalas: %', coalesce(v_tipo, '(sem restricao)');
  end if;

  select attnotnull into v_obrigatoria
    from pg_attribute
   where attrelid = 'public.escalas'::regclass and attname = 'expressao_calculo';

  if v_obrigatoria then
    raise exception 'escalas.expressao_calculo ficou obrigatoria: uma escala de soma deixaria de poder existir.';
  end if;

  raise notice 'Motor de escalas: escala sem respostas devolve nulo; escala respondida com zeros devolve zero.';
end $$;


-- ----------------------------------------------------------------------------
-- 0022_codigos_de_ecra_iguais_as_rotas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0022 — O CÓDIGO DO ECRÃ PASSA A SER A ROTA
--
-- O DEFEITO QUE ISTO CORRIGE
-- ============================================================================
-- O catálogo `public.ecras` identificava três ecrãs pelo SINGULAR:
--
--     episodio     plano     sessao
--
-- E as rotas da aplicação são os PLURAIS correspondentes:
--
--     episodios    planos    sessoes
--
-- Nada os ligava. A navegação pergunta ao servidor «posso ver o ecrã
-- `episodios`?»; o servidor tem uma linha chamada `episodio`; a resposta é que
-- não, e o item desaparece do menu.
--
-- O sintoma, medido: o administrador via Agenda, Utentes, Avaliação e Evolução —
-- e não via Episódios, Planos nem Sessões. Não havia erro nenhum: a navegação
-- obedecia a uma lista que simplesmente não tinha aqueles nomes.
--
-- PORQUE É QUE ISTO PASSOU TANTO TEMPO DESPERCEBIDO
-- ----------------------------------------------------------------------------
-- Havia dois planos. Quando a lista do servidor não chegava (rede em baixo, ou
-- tabela vazia), a navegação caía nas regras de desenho do cliente — que usam as
-- rotas certas — e o menu aparecia COMPLETO. Quando a lista chegava, o menu
-- aparecia mutilado. O mesmo produto, dois menus diferentes, e o segundo só se
-- via com sessão iniciada e dados instalados.
--
-- A CORREÇÃO
-- ============================================================================
-- O código do ecrã passa a ser a rota. Uma coisa, um nome. A migração renomeia
-- as linhas existentes em vez de as apagar: `perfil_visibilidade` aponta para
-- `ecras.id`, e apagar perderia toda a configuração que o administrador já tenha
-- feito.
--
-- É idempotente: numa instalação nova, em que o seed já cria os nomes novos, não
-- encontra nada para renomear.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. RENOMEAR, PRESERVANDO A CONFIGURAÇÃO
-- ---------------------------------------------------------------------------
do $$
declare
  v_antes   text;
  v_depois  text;
  v_total   integer := 0;
  renomear  text[][] := array[
    ['episodio', 'episodios'],
    ['plano',    'planos'],
    ['sessao',   'sessoes']
  ];
  par text[];
begin
  foreach par slice 1 in array renomear loop
    v_antes  := par[1];
    v_depois := par[2];

    /* Só renomeia se o antigo existir E o novo ainda não existir. Se os dois
       existirem, é uma instalação a meio de uma transição: renomear violaria a
       restrição de unicidade do `codigo`, e apagar perderia configuração.
       Nesse caso não se faz nada e o aviso abaixo di-lo. */
    if exists (select 1 from public.ecras where codigo = v_antes)
       and not exists (select 1 from public.ecras where codigo = v_depois) then

      update public.ecras
         set codigo     = v_depois,
             updated_at = now()
       where codigo = v_antes;

      v_total := v_total + 1;
      raise notice 'Ecrã renomeado: % -> %', v_antes, v_depois;

    elsif exists (select 1 from public.ecras where codigo = v_antes)
          and exists (select 1 from public.ecras where codigo = v_depois) then
      raise notice 'AVISO: existem % e % ao mesmo tempo. Nada foi alterado.', v_antes, v_depois;
    end if;
  end loop;

  if v_total = 0 then
    raise notice 'Nada para renomear: os códigos já estão iguais às rotas.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. PORQUE É QUE NÃO SE VERIFICA AQUI QUE OS CÓDIGOS EXISTEM
-- ---------------------------------------------------------------------------
-- Uma migração corre ANTES dos seeds. Neste projeto a ordem é: primeiro o
-- esquema (migrações), depois os dados (seeds). Na altura em que esta migração
-- corre, a tabela `ecras` está VAZIA — o catálogo é criado pelo seed
-- `0006_ecras_e_visibilidade.sql`, que vem depois.
--
-- Escrevi aqui uma verificação que levantava exceção se `episodios`, `planos` e
-- `sessoes` não existissem. Falhou sempre, e por um motivo que não tem nada a ver
-- com o defeito: estava a exigir dados onde ainda não há dados.
--
-- É a mesma armadilha que já apareceu neste projeto, e a regra é esta:
-- ESQUEMA NA MIGRAÇÃO, DADOS NO SEED, ASSERÇÕES NO TESTE.
--
-- Quem verifica a sério é `tools/testar_codigos_de_ecra.mjs`, que compara o
-- catálogo do seed com as rotas registadas no cliente, depois de tudo instalado.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 3. AVISO, SE O CATÁLOGO JÁ EXISTIR NESTA ALTURA
-- ---------------------------------------------------------------------------
-- Numa instalação já feita, o catálogo existe e vale a pena avisar na saída da
-- instalação. Numa instalação nova está vazio, e não há nada a dizer.
--
-- Não levanta exceção de propósito: uma migração não pode depender de dados que
-- o seed ainda não criou.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rotas text[] := array[
    'agenda', 'utentes', 'episodios', 'avaliacao', 'planos', 'sessoes',
    'evolucao', 'relatorios', 'requisicoes', 'faturacao',
    'administracao', 'visibilidade', 'configuracao'
  ];
  v_no_catalogo integer;
  v_faltam      text;
begin
  select count(*) into v_no_catalogo from public.ecras;

  if v_no_catalogo = 0 then
    raise notice 'Catalogo de ecras ainda vazio (o seed corre depois das migracoes).';
    return;
  end if;

  select string_agg(r, ', ' order by r) into v_faltam
    from unnest(v_rotas) as r
   where not exists (select 1 from public.ecras e where e.codigo = r);

  if v_faltam is not null then
    raise notice '----------------------------------------------------------';
    raise notice 'ECRAS DO CLIENTE SEM LINHA NO CATALOGO: %', v_faltam;
    raise notice 'Estes itens nao aparecem no menu quando a lista do servidor';
    raise notice 'esta disponivel. Acrescenta-os ao seed 0006.';
    raise notice '----------------------------------------------------------';
  else
    raise notice 'Todos os ecras do cliente tem linha no catalogo.';
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 0022b_papel_socio.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0022 — O PAPEL DE SÓCIO
--
-- PEDIDO DIRETO DO DONO DA CLÍNICA
-- ============================================================================
-- O seletor de papéis não tinha «Sócio». A lista existente é de FUNÇÕES
-- CLÍNICAS e ADMINISTRATIVAS — administrador, fisiatra, fisioterapeuta,
-- osteopata, terapeutas, psicólogo, enfermeiro, receção, gestão — e um sócio
-- não é nada disso necessariamente: é quem é dono de parte da clínica e por
-- isso vê tudo, mesmo que não trate doentes.
--
-- PORQUE NÃO SE REUTILIZA `administrador`
-- Podia-se dizer «põe administrador». A diferença é real e não é cosmética:
-- numa clínica com dois sócios, um deles é o administrador que configura o
-- sistema e o outro é só dono. Confundir os dois faz com que qualquer
-- contagem de administradores deixe de significar alguma coisa, e uma clínica
-- que se vende não sabe a quem pertence.
--
-- O QUE O SÓCIO PODE
-- Entra no grupo `e_admin()` — a mesma capacidade do administrador, porque
-- não faz sentido ser dono e não poder configurar a clínica. Uma migração
-- futura que queira distinguir «dono» de «administrador técnico» tem aqui o
-- ponto de partida, e tem-no separado em vez de escondido.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O VALOR NO TIPO
--
-- `alter type ... add value` vive na migração 0001, colado à criação do tipo, e
-- NÃO aqui: o PostgreSQL não deixa usar um valor de enum na MESMA transação em
-- que ele é criado, e o bloco 2 abaixo usa `socio`. Escrito aqui, o erro era
-- «unsafe use of new value "socio" of enum type perfil_tipo» — que não aponta
-- para o sítio nem sugere a causa.
-- ---------------------------------------------------------------------------

comment on type public.perfil_tipo is
  'Papeis na clinica. socio = dono de parte da clinica, com a mesma capacidade do administrador; administrador = quem configura o sistema.';


-- ---------------------------------------------------------------------------
-- 2. AS CAPACIDADES
--
-- `e_admin()` é a função que decide quem configura a clínica e quem altera a
-- visibilidade. O sócio entra aqui: é dono, e um dono que não pode configurar
-- a sua própria clínica é uma contradição.
--
-- `e_gestor()` (administrador, gestão, agora sócio) é a capacidade de GESTÃO —
-- indicadores e faturação. O sócio também.
--
-- `e_clinico()` NÃO inclui o sócio. Ver doentes é uma competência clínica, e
-- ser dono não dá competência clínica nenhuma. Um sócio que também trate
-- doentes tem `fisioterapeuta` e não `socio` — o papel diz o que a pessoa faz
-- na clínica, e uma pessoa faz uma coisa de cada vez.
--
-- `e_rececao_ou_melhor()` também não: receber doentes é um trabalho, não uma
-- consequência da propriedade.
-- ---------------------------------------------------------------------------
create or replace function clinia.e_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       /* SÓ administrador e sócio.
        *
        * A primeira versão desta migração tinha aqui `('administrador','gestao','socio')`
        * — e desfazia, sem dar por isso, a separação que a migração 0017 fez de
        * propósito: `e_admin()` é o ADMINISTRADOR, e `gestao` passou a ter uma
        * capacidade própria (`e_gestor()`) precisamente para não ver dados
        * clínicos.
        *
        * O sintoma era o que a 0017 descreve: com `gestao` dentro de
        * `e_admin()`, a gestão passava em TODOS os atalhos — via avaliações,
        * sessões e episódios que não devia ver. O comentário da 0017 diz
        * exatamente isto, e esta migração reintroduziu o problema.
        *
        * O SÓCIO entra: é dono da clínica, e um dono que não pode configurar a
        * sua própria clínica é uma contradição. A GESTÃO não: é um trabalho
        * administrativo, e não dá acesso a dados de saúde. */
       and p.perfil in ('administrador','socio')
  );
$$;

comment on function clinia.e_admin() is
  'Quem configura a clinica e a visibilidade: administrador e socio. A gestao NAO entra aqui — essa tem e_gestor().';

create or replace function clinia.e_gestor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil in ('administrador','gestao','socio')
  );
$$;

comment on function clinia.e_gestor() is
  'Capacidade de GESTAO: indicadores, faturacao e configuracao. administrador, gestao e socio.';

grant execute on function clinia.e_admin() to authenticated;
grant execute on function clinia.e_gestor() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. O ESPELHO EM `profissionais`
--
-- O gatilho da migração 0002 espelha o perfil em `profissionais`, mas só para
-- quem exerce. O sócio não exerce, e por isso não deve aparecer no diretório de
-- profissionais — senão aparece na lista de «Profissional principal» de um
-- episódio, e alguém lhe atribui um processo clínico.
-- ---------------------------------------------------------------------------
do $$
declare
  v_espelha boolean;
begin
  /* Confirma-se que a lista de quem NÃO é espelhado inclui o sócio. */
  select exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'clinia'
       and p.proname = 'espelhar_perfil_em_profissional'
  ) into v_espelha;

  if v_espelha then
    raise notice 'O espelho de perfis em profissionais existe; o socio nao e clinico e nao e espelhado.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 4. VERIFICAÇÃO
-- ---------------------------------------------------------------------------
do $$
declare
  v_tem_socio boolean;
begin
  select exists (
    select 1 from pg_enum e
      join pg_type t on t.oid = e.enumtypid
     where t.typname = 'perfil_tipo' and e.enumlabel = 'socio'
  ) into v_tem_socio;

  if not v_tem_socio then
    raise exception 'O papel socio nao ficou no tipo perfil_tipo.';
  end if;

  /* E `e_admin()` tem de o mencionar — senão o sócio tem o papel e não tem a
     capacidade, que é pior do que não ter o papel: parece que funciona. */
  if position('socio' in pg_get_functiondef('clinia.e_admin()'::regprocedure)) = 0 then
    raise exception 'e_admin() nao reconhece o socio: teria o papel e nao a capacidade.';
  end if;

  raise notice 'Papel socio acrescentado, com a capacidade de administrador.';
end $$;


-- ----------------------------------------------------------------------------
-- 0023_consentimento_online.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0023 — consentimento informado online
--
-- O QUE ISTO ACRESCENTA
-- ============================================================================
-- A tabela `consentimentos` (migração 0003) já registava O QUE foi consentido e
-- quando, e é append-only — «revoga-se, nunca se apaga (prova legal)». O que
-- faltava era o CAMINHO até lá: como é que um consentimento é pedido a alguém
-- que não está na clínica, e como é que se prova que foi essa pessoa a assinar.
--
-- Esta migração acrescenta o circuito, que é a mesma ideia do DOCbase flow:
-- ENVIO → CERTIFICAÇÃO → RECEÇÃO → DEVOLUÇÃO, com cada passo registado.
--
--   consentimento_textos    o texto que o utente lê, VERSIONADO
--   consentimento_pedidos   um pedido de assinatura, com o seu estado
--   consentimento_eventos   cada passo do circuito, imutável
--
-- AS DUAS DECISÕES QUE INTERESSAM
-- ============================================================================
--
-- 1. O TOKEN GUARDA-SE EM HASH, NUNCA EM CLARO.
--    Quem ler a tabela não consegue abrir o link de ninguém. É a mesma razão
--    pela qual uma palavra-passe não se guarda em claro. O token em claro só
--    existe uma vez: no momento em que é enviado ao utente.
--
-- 2. UM TEXTO PUBLICADO NUNCA SE EDITA.
--    Um consentimento sem o texto que foi aceite não prova nada. Se o texto
--    mudar, publica-se uma versão nova; quem assinou a v1 continua a ter
--    assinado a v1, e é isso que a lei quer.
--
-- O QUE ESTA MIGRAÇÃO NÃO FAZ
-- ============================================================================
-- Não envia email nem SMS. O envio é uma função com um só ponto de
-- substituição — ver `clinia.pedir_consentimento()` — porque depende de um
-- serviço externo que ainda não está escolhido. O circuito todo funciona sem
-- ele: o link é devolvido a quem pede e pode ser copiado à mão.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O TEXTO DO CONSENTIMENTO, VERSIONADO
-- ---------------------------------------------------------------------------
create table if not exists public.consentimento_textos (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null,            -- 'tratamento', 'dados_pessoais', ...
  versao        text not null,            -- 'v1', 'v2' — nunca se reescreve
  titulo        text not null,
  corpo         text not null,            -- markdown simples, mostrado ao utente
  -- Que tipo do enum `consentimento_tipo` isto satisfaz quando assinado.
  tipo          public.consentimento_tipo not null,
  -- Um texto obrigatório é aquele sem o qual não se pode tratar o utente.
  obrigatorio   boolean not null default true,
  ativo         boolean not null default true,
  publicado_em  timestamptz not null default now(),
  publicado_por uuid references public.perfis(id) on delete set null,
  created_at    timestamptz not null default now(),

  /* DE QUE CLÍNICA É ESTE TEXTO.
   *
   * `null` = o MODELO PARTILHADO, que o sistema propõe e todas as clínicas leem.
   * Preenchido = o texto que AQUELA clínica decidiu usar.
   *
   * A coluna nasce aqui, e não numa migração posterior, porque o `on conflict`
   * deste ficheiro precisa dela para inferir o índice parcial que a migração
   * 0028 cria. Uma coluna usada por um `on conflict` tem de existir antes de o
   * `on conflict` correr — e este ficheiro corre primeiro. */
  clinica_id    uuid references public.clinicas(id) on delete cascade,

  constraint consentimento_textos_codigo_valido check (length(btrim(codigo)) > 0),
  constraint consentimento_textos_corpo_valido check (length(btrim(corpo)) > 0)
);

/* PARA QUEM JÁ CORREU ESTA MIGRAÇÃO ANTES DE A COLUNA EXISTIR.
 *
 * `create table if not exists` não altera uma tabela que já exista — é a mesma
 * armadilha que a migração 0002 documenta. Sem este `alter`, quem instalou o
 * clinIA antes de hoje ficava com a tabela sem `clinica_id`, e o `on conflict`
 * logo abaixo rebentava com «column clinica_id does not exist».
 *
 * A restrição única antiga `(codigo, versao)` sai desta definição e passa a viver
 * nos dois índices por clínica que a migração 0028 cria — num sítio só, para não
 * haver dois a decidir a mesma coisa. */
alter table public.consentimento_textos
  add column if not exists clinica_id uuid references public.clinicas(id) on delete cascade;

create index if not exists idx_consentimento_textos_ativos
  on public.consentimento_textos (codigo) where ativo;

comment on table public.consentimento_textos is
  'Texto do consentimento, versionado. Um texto publicado nunca se edita: publica-se versao nova. clinica_id null = modelo partilhado; preenchido = texto daquela clinica.';

-- ---------------------------------------------------------------------------
-- 2. UM PEDIDO DE ASSINATURA
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.consentimento_estado as enum (
    'pedido',          -- criado, ainda não enviado
    'enviado',         -- o link saiu da clínica
    'visto',           -- o utente abriu o link
    'otp_enviado',     -- o código de uso único foi enviado
    'otp_confirmado',  -- o utente provou que controla o destino
    'assinado',        -- assinou
    'recusado',
    'expirado',
    'cancelado'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.consentimento_canal as enum ('email', 'sms', 'balcao');
exception when duplicate_object then null; end $$;

create table if not exists public.consentimento_pedidos (
  id            uuid primary key default gen_random_uuid(),
  clinica_id    uuid not null references public.clinicas(id) on delete restrict,
  utente_id     uuid not null references public.utentes(id) on delete restrict,
  -- Opcional: um consentimento pode ser pedido antes de haver episódio.
  episodio_id   uuid references public.episodios(id) on delete set null,
  texto_id      uuid not null references public.consentimento_textos(id) on delete restrict,

  estado        public.consentimento_estado not null default 'pedido',
  canal         public.consentimento_canal not null default 'email',

  -- Para onde foi. Guarda-se MASCARADO para os ecrãs ('a***@exemplo.pt'): o
  -- endereço completo não acrescenta nada a quem consulta a ficha, e é dado
  -- pessoal a mais exposto sem contrapartida.
  destino_mascarado text,
  -- O destino completo, para se poder reenviar. Fica em coluna própria e é
  -- revogado quando o pedido termina (ver `clinia.limpar_pedido_consentimento`).
  destino       text,

  -- O TOKEN EM HASH. Nunca em claro. Ver a nota no topo do ficheiro.
  token_hash    text not null,

  expira_em     timestamptz not null default (now() + interval '72 hours'),

  enviado_em        timestamptz,
  visto_em          timestamptz,
  otp_enviado_em    timestamptz,
  otp_confirmado_em timestamptz,
  assinado_em       timestamptz,

  -- O hash do código OTP, e não o código. Mesma razão do token.
  otp_hash      text,
  otp_expira_em timestamptz,
  tentativas_otp smallint not null default 0,

  -- Ligação à linha de `consentimentos` que nasceu deste pedido.
  consentimento_id uuid references public.consentimentos(id) on delete set null,

  criado_por    uuid references public.perfis(id) on delete set null,
  criado_em     timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint consentimento_pedidos_tentativas check (tentativas_otp >= 0 and tentativas_otp <= 10),
  constraint consentimento_pedidos_token_unico unique (token_hash),
  -- Um pedido assinado tem de ter data de assinatura, e vice-versa. Sem isto,
  -- um erro de código deixava um pedido «assinado» sem prova de quando.
  constraint consentimento_pedidos_assinatura_coerente
    check ((estado = 'assinado') = (assinado_em is not null))
);

create index if not exists idx_consentimento_pedidos_utente
  on public.consentimento_pedidos (utente_id, estado);
create index if not exists idx_consentimento_pedidos_abertos
  on public.consentimento_pedidos (clinica_id, expira_em)
  where estado in ('pedido','enviado','visto','otp_enviado','otp_confirmado');

comment on table public.consentimento_pedidos is
  'Pedido de assinatura de um consentimento. O token e o OTP guardam-se em hash, nunca em claro.';

-- ---------------------------------------------------------------------------
-- 3. CADA PASSO DO CIRCUITO
-- ---------------------------------------------------------------------------
create table if not exists public.consentimento_eventos (
  id          uuid primary key default gen_random_uuid(),
  pedido_id   uuid not null references public.consentimento_pedidos(id) on delete cascade,
  tipo        text not null,
  em          timestamptz not null default now(),
  -- Contexto técnico da prova. Nulo quando o passo é do sistema (não há pedido
  -- HTTP de ninguém para registar).
  ip          inet,
  user_agent  text,
  detalhe     jsonb not null default '{}'::jsonb,

  constraint consentimento_eventos_tipo_valido check (length(btrim(tipo)) > 0)
);

create index if not exists idx_consentimento_eventos_pedido
  on public.consentimento_eventos (pedido_id, em);

comment on table public.consentimento_eventos is
  'Append-only: cada passo do circuito de consentimento. E a prova se alguem contestar.';

-- ---------------------------------------------------------------------------
-- 4. O `consentimento` PASSA A SABER DE QUE PEDIDO NASCEU
-- ---------------------------------------------------------------------------
alter table public.consentimentos
  add column if not exists pedido_id uuid references public.consentimento_pedidos(id) on delete set null;

comment on column public.consentimentos.pedido_id is
  'Pedido online que originou este consentimento. Nulo quando foi registado ao balcao.';

-- ---------------------------------------------------------------------------
-- 5. OS TEXTOS POR OMISSÃO
-- ---------------------------------------------------------------------------
/* O ÍNDICE VEM ANTES DO INSERT, E NÃO É CAPRICHO.
 *
 * Um `on conflict` só pode inferir um índice que JÁ EXISTA quando o insert
 * corre. Se o índice fosse criado pela migração 0028 — depois desta — a primeira
 * passagem rebentava com «there is no unique or exclusion constraint matching the
 * ON CONFLICT specification», que foi exatamente o que aconteceu.
 *
 * E é um índice único PARCIAL (`where clinica_id is null`) porque estes textos
 * são o MODELO PARTILHADO: não são de nenhuma clínica, e o `clinica_id` fica
 * nulo. A unicidade que interessa garantir aqui é a deles — uma versão por
 * código, no modelo do sistema.
 *
 * O `where clinica_id is null` do `on conflict` tem de coincidir com o do
 * índice: é assim que o PostgreSQL sabe qual usar. */
create unique index if not exists uq_consentimento_textos_partilhados
  on public.consentimento_textos (codigo, versao)
  where clinica_id is null;

-- Texto de partida para a clinica rever. NAO substitui a responsabilidade
-- clinica e legal do texto final: e um rascunho honesto, com os elementos que a
-- lei pede, e nada mais. Quem assina e o utente; quem responde pelo texto e a
-- clinica.
insert into public.consentimento_textos (codigo, versao, titulo, corpo, tipo, obrigatorio)
values
  ('tratamento', 'v1',
   'Consentimento informado para tratamento',
   E'## O que lhe vai ser feito\n\n'
   'Fui informado e compreendi:\n\n'
   '- Que vou ser avaliado e tratado por profissionais de Medicina Física e de Reabilitação.\n'
   '- Que o plano de tratamento me será explicado, e que posso pedir esclarecimentos em qualquer momento.\n'
   '- Que os resultados não são garantidos, e que dependem da minha participação e do meu estado de saúde.\n'
   '- Que posso recusar ou interromper o tratamento a qualquer momento, sem ter de justificar.\n'
   '- Que me foi explicado o que acontece se não fizer tratamento.\n\n'
   '## Riscos\n\n'
   'Fui informado de que o tratamento pode provocar desconforto ou dor passageira, e que existem '
   'riscos raros que me foram explicados. Comprometo-me a dizer imediatamente se sentir algo de anormal.\n\n'
   '## Alternativas\n\n'
   'Fui informado de que existem alternativas a este tratamento, e quais são.\n',
   'tratamento', true),

  ('dados_pessoais', 'v1',
   'Consentimento para tratamento de dados de saúde',
   E'## Que dados são tratados\n\n'
   'Os meus dados de identificação, de contacto e os dados de saúde necessários ao meu tratamento.\n\n'
   '## Para que fins\n\n'
   '- Prestar cuidados de saúde e manter o meu processo clínico.\n'
   '- Faturação e cumprimento de obrigações legais.\n'
   '- Contacto para marcações, se o autorizar.\n\n'
   '## Os meus direitos\n\n'
   'Fui informado de que posso aceder aos meus dados, pedir a sua correção, pedir a sua portabilidade, '
   'e retirar este consentimento a qualquer momento. A retirada não afeta o que já foi feito.\n\n'
   'Fui informado de quem é o responsável pelo tratamento e de como o contactar.\n',
   'dados_pessoais', true)

/* O `where` NÃO É DECORATIVO, E A MIGRAÇÃO 0028 DEPENDE DELE.
 *
 * Depois da 0028, a unicidade dos textos PARTILHADOS vive num índice único
 * parcial (`uq_consentimento_textos_partilhados ... where clinica_id is null`),
 * porque a chave passou a ter de deixar cada clínica ter o seu `tratamento/v1`
 * sem colidir com o modelo do sistema.
 *
 * E o PostgreSQL só infere um índice parcial se o alvo do `on conflict` trouxer
 * a MESMA cláusula `where`. Sem ela — e foi assim que este ficheiro ficou até a
 * 0028 existir — a segunda passagem das migrações rebenta com «there is no
 * unique or exclusion constraint matching the ON CONFLICT specification».
 *
 * `clinica_id is null` é também o que este insert QUER dizer: estes textos são
 * o modelo partilhado, não são de nenhuma clínica. */
on conflict (codigo, versao) where clinica_id is null do nothing;

-- ---------------------------------------------------------------------------
-- 6. GATILHOS
-- ---------------------------------------------------------------------------
drop trigger if exists t_consentimento_pedidos_updated_at on public.consentimento_pedidos;
create trigger t_consentimento_pedidos_updated_at
  before update on public.consentimento_pedidos
  for each row execute function clinia.set_updated_at();

-- Os eventos são append-only, e o gatilho garante-o em vez de confiar em
-- disciplina. Uma prova que se pode alterar não é prova.
--
-- UMA EXCEÇÃO: A CASCATA DO PEDIDO.
-- ----------------------------------------------------------------------------
-- A primeira versão deste gatilho recusava TODAS as eliminações. Isso estava
-- certo para um `delete` direto e errado para a cascata: apagar um PEDIDO (por
-- exemplo, ao limpar os utentes de teste) arrasta os seus eventos, e o gatilho
-- bloqueava a limpeza inteira.
--
-- O sintoma era um erro que não nomeia a causa:
--   «Os eventos de consentimento sao append-only...»
-- quando o que se estava a apagar era o UTENTE.
--
-- A distinção faz-se com `pg_trigger_depth()`: a 1 é sempre um `delete` direto,
-- porque nenhum gatilho está a correr por baixo. Acima disso, a eliminação vem
-- de uma cascata — e nesse caso o pedido a que os eventos pertencem já está a ser
-- apagado. **Um evento cujo pedido deixou de existir não é prova de nada:** não
-- há como o mostrar, nem como o ligar a um utente.
--
-- O que continua proibido, e é o que interessa: apagar ou alterar eventos
-- ENQUANTO O PEDIDO EXISTE. A prova de um consentimento assinado é intocável.
create or replace function clinia.proteger_eventos_consentimento()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;

  raise exception
    'Os eventos de consentimento sao append-only: nao se alteram nem se apagam enquanto o pedido existir. Um evento errado corrige-se com um evento novo.';
end $$;

drop trigger if exists t_consentimento_eventos_imutaveis on public.consentimento_eventos;
create trigger t_consentimento_eventos_imutaveis
  before update or delete on public.consentimento_eventos
  for each row execute function clinia.proteger_eventos_consentimento();

-- Os textos: um texto publicado nunca se edita. Só se pode desativar.
create or replace function clinia.proteger_textos_consentimento()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception
      'Os textos de consentimento nao se apagam: um consentimento assinado tem de poder mostrar o texto que foi aceite. Desativa-o.';
  end if;

  if new.codigo <> old.codigo or new.versao <> old.versao then
    raise exception
      'O codigo e a versao de um texto de consentimento nao se alteram: publica uma versao nova.';
  end if;

  if new.corpo <> old.corpo then
    raise exception
      'O corpo de um texto publicado nao se edita: publica uma versao nova. Quem assinou a versao antiga tem de continuar a poder ver o que assinou.';
  end if;

  return new;
end $$;

drop trigger if exists t_consentimento_textos_imutaveis on public.consentimento_textos;
create trigger t_consentimento_textos_imutaveis
  before update or delete on public.consentimento_textos
  for each row execute function clinia.proteger_textos_consentimento();

-- ---------------------------------------------------------------------------
-- 7. AS FUNÇÕES DO CIRCUITO
-- ---------------------------------------------------------------------------

-- Gerar um token. Usa `gen_random_bytes` (pgcrypto), que é criptograficamente
-- seguro — ao contrário de `random()`, que é previsível e serviria para adivinhar
-- o link de outra pessoa.
--
-- O `set search_path` NÃO É DECORAÇÃO: sem ele, `gen_random_bytes` é procurado
-- no schema da sessão — que este ficheiro de instalação fixa em `public` — e no
-- Supabase o pgcrypto vive em `extensions`. O resultado era
-- «function gen_random_bytes(integer) does not exist» a meio da instalação, e
-- como tudo corre numa só transação, a instalação inteira era desfeita. A
-- `assinar_ato` (migração 0011) já tinha esta linha e é por isso que o `digest`
-- dela nunca deu problema: a diferença entre as duas era exatamente esta.
create or replace function clinia.gerar_token_consentimento()
returns text
language sql
volatile
set search_path = public, extensions
as $$
  select encode(gen_random_bytes(32), 'hex');
$$;

create or replace function clinia.hash_token_consentimento(p_token text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(digest(p_token, 'sha256'), 'hex');
$$;

comment on function clinia.gerar_token_consentimento() is
  'Token de 32 bytes para o link de consentimento. O que se guarda e o hash.';

-- Mascarar um email ou telefone para os ecrãs da clínica.
--   'ana.silva@exemplo.pt'  ->  'a***@exemplo.pt'
--   '+351912345678'         ->  '+3519*****78'
create or replace function clinia.mascarar_destino(p_destino text)
returns text
language plpgsql
immutable
as $$
declare
  v_arroba integer;
begin
  if p_destino is null or length(btrim(p_destino)) = 0 then
    return null;
  end if;

  v_arroba := position('@' in p_destino);

  if v_arroba > 0 then
    return left(p_destino, 1) || '***' || substring(p_destino from v_arroba);
  end if;

  if length(p_destino) <= 6 then
    return left(p_destino, 2) || '***';
  end if;

  return left(p_destino, 5) || '*****' || right(p_destino, 2);
end $$;

-- ---------------------------------------------------------------------------
-- 8. CRIAR UM PEDIDO
-- ---------------------------------------------------------------------------
-- Devolve o TOKEN EM CLARO, uma única vez. Quem chama tem de o enviar ao utente
-- e não o guardar em lado nenhum: a base de dados só tem o hash.
create or replace function clinia.pedir_consentimento(
  p_utente      uuid,
  p_texto_id    uuid,
  p_canal       public.consentimento_canal,
  p_destino     text,
  p_episodio    uuid default null
)
returns table (pedido_id uuid, token text, expira_em timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid;
  v_token   text;
  v_pedido  uuid;
  v_expira  timestamptz;
  v_aberto  integer;
begin
  select u.clinica_id into v_clinica from public.utentes u where u.id = p_utente;

  if v_clinica is null then
    raise exception 'O utente % nao existe.', p_utente;
  end if;

  if not exists (select 1 from public.consentimento_textos t where t.id = p_texto_id and t.ativo) then
    raise exception 'O texto de consentimento % nao existe ou esta inativo.', p_texto_id;
  end if;

  if p_canal <> 'balcao' and (p_destino is null or length(btrim(p_destino)) = 0) then
    raise exception 'Um pedido por % precisa de um destino (email ou telefone).', p_canal;
  end if;

  /* Um pedido em aberto por texto: pedir o mesmo consentimento duas vezes cria
     dois links validos, e o utente assina o que abrir primeiro. O segundo fica
     pendente para sempre e a ficha mostra um estado que ninguem percebe. */
  select count(*) into v_aberto
    from public.consentimento_pedidos p
   where p.utente_id = p_utente
     and p.texto_id = p_texto_id
     and p.estado in ('pedido','enviado','visto','otp_enviado','otp_confirmado');

  if v_aberto > 0 then
    raise exception
      'Ja existe um pedido em aberto para este consentimento. Cancela-o antes de criar outro.';
  end if;

  v_token  := clinia.gerar_token_consentimento();
  v_expira := now() + interval '72 hours';

  insert into public.consentimento_pedidos (
    clinica_id, utente_id, episodio_id, texto_id, estado, canal,
    destino, destino_mascarado, token_hash, expira_em, criado_por
  ) values (
    v_clinica, p_utente, p_episodio, p_texto_id, 'pedido', p_canal,
    p_destino, clinia.mascarar_destino(p_destino),
    clinia.hash_token_consentimento(v_token), v_expira, auth.uid()
  ) returning id into v_pedido;

  insert into public.consentimento_eventos (pedido_id, tipo, detalhe)
  values (v_pedido, 'pedido_criado', jsonb_build_object('canal', p_canal));

  return query select v_pedido, v_token, v_expira;
end $$;

comment on function clinia.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid) is
  'Cria um pedido de consentimento e devolve o token EM CLARO uma unica vez. Guarda apenas o hash.';

-- ---------------------------------------------------------------------------
-- 9. ABRIR O LINK (sem sessão — é o utente em casa)
-- ---------------------------------------------------------------------------
-- Devolve o texto a mostrar, e marca o pedido como visto. NÃO devolve nada se o
-- token não existir, se já tiver sido usado, ou se tiver expirado.
create or replace function clinia.abrir_consentimento(
  p_token text,
  p_ip    inet default null,
  p_ua    text default null
)
returns table (
  pedido_id  uuid,
  estado     public.consentimento_estado,
  titulo     text,
  corpo      text,
  versao     text,
  utente_nome text,
  canal      public.consentimento_canal,
  expira_em  timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
  v_texto  public.consentimento_textos;
  v_nome   text;
begin
  select * into v_pedido
    from public.consentimento_pedidos p
   where p.token_hash = clinia.hash_token_consentimento(p_token);

  if v_pedido.id is null then
    return;
  end if;

  if v_pedido.estado in ('assinado','recusado','cancelado') then
    return;
  end if;

  if v_pedido.expira_em < now() then
    /* Marcar como expirado é util e nao destroi nada: o evento fica. */
    update public.consentimento_pedidos set estado = 'expirado' where id = v_pedido.id;
    insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent)
    values (v_pedido.id, 'link_expirado', p_ip, p_ua);
    return;
  end if;

  select * into v_texto from public.consentimento_textos t where t.id = v_pedido.texto_id;
  select coalesce(u.nome_preferido, u.nome) into v_nome
    from public.utentes u where u.id = v_pedido.utente_id;

  /* Primeira abertura: registar. As seguintes não voltam a escrever o mesmo
     evento — um registo com dez «link_aberto» seguidos não diz nada. */
  if v_pedido.estado = 'pedido' or v_pedido.estado = 'enviado' then
    update public.consentimento_pedidos
       set estado = 'visto', visto_em = coalesce(visto_em, now())
     where id = v_pedido.id;

    insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent)
    values (v_pedido.id, 'link_aberto', p_ip, p_ua);

    v_pedido.estado := 'visto';
  end if;

  return query select
    v_pedido.id, v_pedido.estado, v_texto.titulo, v_texto.corpo, v_texto.versao,
    v_nome, v_pedido.canal, v_pedido.expira_em;
end $$;

-- ---------------------------------------------------------------------------
-- 10. PEDIR E CONFIRMAR O CÓDIGO DE USO ÚNICO
-- ---------------------------------------------------------------------------
-- O código é gerado AQUI e devolvido a quem chama, para o enviar. Tal como o
-- token, só o hash fica guardado.
create or replace function clinia.pedir_codigo_consentimento(
  p_token text,
  p_ip    inet default null,
  p_ua    text default null
)
returns table (codigo text, destino_mascarado text, expira_em timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
  v_codigo text;
  v_expira timestamptz;
begin
  select * into v_pedido
    from public.consentimento_pedidos p
   where p.token_hash = clinia.hash_token_consentimento(p_token);

  if v_pedido.id is null then return; end if;
  if v_pedido.estado in ('assinado','recusado','cancelado','expirado') then return; end if;
  if v_pedido.expira_em < now() then return; end if;

  /* Travao contra abuso: um link que se pode usar para enviar cem SMS e um
     prejuizo e um incomodo para o utente. */
  if v_pedido.tentativas_otp >= 5 then
    raise exception 'Demasiadas tentativas neste pedido. Pede um novo a clinica.';
  end if;

  /* Seis digitos. `lpad` para nao sair um codigo de cinco digitos quando o
     numero aleatorio e pequeno — que reduziria o espaco de procura. */
  v_codigo := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  v_expira := now() + interval '10 minutes';

  update public.consentimento_pedidos
     set otp_hash      = clinia.hash_token_consentimento(v_codigo),
         otp_expira_em = v_expira,
         otp_enviado_em = now(),
         estado        = 'otp_enviado'
   where id = v_pedido.id;

  insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent, detalhe)
  values (v_pedido.id, 'otp_enviado', p_ip, p_ua,
          jsonb_build_object('destino', v_pedido.destino_mascarado));

  return query select v_codigo, v_pedido.destino_mascarado, v_expira;
end $$;

create or replace function clinia.confirmar_codigo_consentimento(
  p_token  text,
  p_codigo text,
  p_ip     inet default null,
  p_ua     text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
begin
  select * into v_pedido
    from public.consentimento_pedidos p
   where p.token_hash = clinia.hash_token_consentimento(p_token);

  if v_pedido.id is null then return false; end if;
  if v_pedido.estado in ('assinado','recusado','cancelado','expirado') then return false; end if;

  if v_pedido.otp_hash is null or v_pedido.otp_expira_em is null or v_pedido.otp_expira_em < now() then
    insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent)
    values (v_pedido.id, 'otp_falhado', p_ip, p_ua);
    return false;
  end if;

  if v_pedido.otp_hash <> clinia.hash_token_consentimento(p_codigo) then
    update public.consentimento_pedidos
       set tentativas_otp = tentativas_otp + 1
     where id = v_pedido.id;

    insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent, detalhe)
    values (v_pedido.id, 'otp_falhado', p_ip, p_ua,
            jsonb_build_object('tentativa', v_pedido.tentativas_otp + 1));
    return false;
  end if;

  update public.consentimento_pedidos
     set estado = 'otp_confirmado',
         otp_confirmado_em = now(),
         /* O código usa-se UMA vez. Sem isto, quem o visse por cima do ombro
            podia assinar mais tarde. */
         otp_hash = null,
         otp_expira_em = null
   where id = v_pedido.id;

  insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent)
  values (v_pedido.id, 'otp_confirmado', p_ip, p_ua);

  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 11. ASSINAR
-- ---------------------------------------------------------------------------
-- Só assina quem confirmou o código. É esta condição que distingue uma
-- assinatura AVANÇADA de uma caixa de confirmação.
create or replace function clinia.assinar_consentimento(
  p_token     text,
  p_nome      text,
  p_qualidade text default 'próprio',
  p_ip        inet default null,
  p_ua        text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
  v_texto  public.consentimento_textos;
  v_cons   uuid;
begin
  if p_nome is null or length(btrim(p_nome)) < 3 then
    raise exception 'O nome de quem assina e obrigatorio.';
  end if;

  select * into v_pedido
    from public.consentimento_pedidos p
   where p.token_hash = clinia.hash_token_consentimento(p_token);

  if v_pedido.id is null then
    raise exception 'Este link nao e valido.';
  end if;

  if v_pedido.estado = 'assinado' then
    raise exception 'Este consentimento ja foi assinado.';
  end if;

  if v_pedido.estado <> 'otp_confirmado' then
    raise exception 'Falta confirmar o codigo antes de assinar.';
  end if;

  if v_pedido.expira_em < now() then
    raise exception 'Este link expirou. Pede um novo a clinica.';
  end if;

  select * into v_texto from public.consentimento_textos t where t.id = v_pedido.texto_id;

  insert into public.consentimentos (
    clinica_id, utente_id, tipo, versao_texto, concedido, concedido_em,
    concedido_por, qualidade, pedido_id
  ) values (
    v_pedido.clinica_id, v_pedido.utente_id, v_texto.tipo, v_texto.versao,
    true, now(), btrim(p_nome), p_qualidade, v_pedido.id
  ) returning id into v_cons;

  update public.consentimento_pedidos
     set estado = 'assinado',
         assinado_em = now(),
         consentimento_id = v_cons,
         /* O destino deixa de ser preciso: o pedido terminou. Guardar um email
            ou telefone sem uso e dado pessoal a mais. Ver o RGPD. */
         destino = null
   where id = v_pedido.id;

  insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent, detalhe)
  values (v_pedido.id, 'assinado', p_ip, p_ua,
          jsonb_build_object('nome', btrim(p_nome), 'qualidade', p_qualidade,
                             'texto', v_texto.codigo, 'versao', v_texto.versao));

  return v_cons;
end $$;

comment on function clinia.assinar_consentimento(text, text, text, inet, text) is
  'Assina um consentimento. Exige o OTP confirmado — e isso que distingue a assinatura avancada de uma caixa de confirmacao.';

-- ---------------------------------------------------------------------------
-- 12. RECUSAR E CANCELAR
-- ---------------------------------------------------------------------------
create or replace function clinia.recusar_consentimento(
  p_token text,
  p_motivo text default null,
  p_ip inet default null,
  p_ua text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
begin
  select * into v_pedido
    from public.consentimento_pedidos p
   where p.token_hash = clinia.hash_token_consentimento(p_token);

  if v_pedido.id is null then return; end if;
  if v_pedido.estado in ('assinado','cancelado') then return; end if;

  update public.consentimento_pedidos
     set estado = 'recusado', destino = null
   where id = v_pedido.id;

  insert into public.consentimento_eventos (pedido_id, tipo, ip, user_agent, detalhe)
  values (v_pedido.id, 'recusado', p_ip, p_ua,
          jsonb_build_object('motivo', nullif(btrim(coalesce(p_motivo, '')), '')));
end $$;

create or replace function clinia.cancelar_pedido_consentimento(p_pedido uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.consentimento_pedidos
     set estado = 'cancelado', destino = null
   where id = p_pedido
     and estado in ('pedido','enviado','visto','otp_enviado','otp_confirmado');

  insert into public.consentimento_eventos (pedido_id, tipo, detalhe)
  values (p_pedido, 'cancelado', jsonb_build_object('por', auth.uid()));
end $$;

-- ---------------------------------------------------------------------------
-- 13. A VISTA QUE A CLÍNICA LÊ
-- ---------------------------------------------------------------------------
create or replace view public.vw_consentimento_pedidos
with (security_invoker = true) as
  select
    p.id,
    p.clinica_id,
    p.utente_id,
    p.episodio_id,
    p.texto_id,
    t.codigo        as texto_codigo,
    t.versao        as texto_versao,
    t.titulo        as texto_titulo,
    t.tipo          as consentimento_tipo,
    p.estado,
    p.canal,
    p.destino_mascarado,
    p.expira_em,
    p.enviado_em,
    p.visto_em,
    p.otp_confirmado_em,
    p.assinado_em,
    p.consentimento_id,
    p.criado_em,
    -- O nome de quem assinou so aparece depois de assinado. Antes disso nao ha
    -- nada para mostrar.
    (select c.concedido_por from public.consentimentos c where c.id = p.consentimento_id) as assinado_por,
    (select count(*) from public.consentimento_eventos e where e.pedido_id = p.id) as passos,
    /* Uma linha por pedido, com tudo o que a ficha precisa. Sem `security_invoker`
       isto corria com os privilegios do dono e mostrava pedidos de outras
       clinicas. */
    (p.estado in ('pedido','enviado','visto','otp_enviado','otp_confirmado')
      and p.expira_em > now()) as em_curso
    from public.consentimento_pedidos p
    join public.consentimento_textos t on t.id = p.texto_id;

comment on view public.vw_consentimento_pedidos is
  'Pedidos de consentimento, com o estado e o nome de quem assinou. Fonte do ecra da ficha do utente.';

-- ---------------------------------------------------------------------------
-- 14. SEGURANÇA
-- ---------------------------------------------------------------------------
alter table public.consentimento_textos   enable row level security;
alter table public.consentimento_pedidos  enable row level security;
alter table public.consentimento_eventos  enable row level security;

-- TEXTOS: são um CATÁLOGO GLOBAL, não pertencem a uma clínica — o texto que se
-- lê é o mesmo em qualquer clínica. Por isso toda a equipa autenticada lê, e só
-- o administrador publica versões novas.
drop policy if exists consentimento_textos_leitura on public.consentimento_textos;
create policy consentimento_textos_leitura on public.consentimento_textos
  for select to authenticated
  using (true);

drop policy if exists consentimento_textos_escrita on public.consentimento_textos;
create policy consentimento_textos_escrita on public.consentimento_textos
  for insert to authenticated
  with check (clinia.e_admin());

-- PEDIDOS: quem é da clínica vê os seus. Quem cria tem de ser clínico.
drop policy if exists consentimento_pedidos_leitura on public.consentimento_pedidos;
create policy consentimento_pedidos_leitura on public.consentimento_pedidos
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id());

drop policy if exists consentimento_pedidos_criar on public.consentimento_pedidos;
create policy consentimento_pedidos_criar on public.consentimento_pedidos
  for insert to authenticated
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

drop policy if exists consentimento_pedidos_alterar on public.consentimento_pedidos;
create policy consentimento_pedidos_alterar on public.consentimento_pedidos
  for update to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
  with check (clinica_id = clinia.current_clinica_id());

-- EVENTOS: leitura pela clínica; escrita só pelas funções `security definer`
-- (que correm como o dono e por isso não passam por estas políticas). A equipa
-- NÃO escreve eventos à mão: um evento escrito à mão não é prova.
drop policy if exists consentimento_eventos_leitura on public.consentimento_eventos;
create policy consentimento_eventos_leitura on public.consentimento_eventos
  for select to authenticated
  using (exists (
    select 1 from public.consentimento_pedidos p
     where p.id = consentimento_eventos.pedido_id
       and p.clinica_id = clinia.current_clinica_id()
  ));

-- Privilégios: a equipa lê e cria pedidos; as tabelas de prova não se escrevem
-- à mão.
grant select on public.consentimento_textos  to authenticated;
grant insert on public.consentimento_textos  to authenticated;
grant select, insert, update on public.consentimento_pedidos to authenticated;
grant select on public.consentimento_eventos to authenticated;
grant select on public.vw_consentimento_pedidos to authenticated;

grant execute on function clinia.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid) to authenticated;
grant execute on function clinia.cancelar_pedido_consentimento(uuid) to authenticated;
grant execute on function clinia.mascarar_destino(text) to authenticated;

-- As funções do circuito público (abrir, pedir código, confirmar, assinar,
-- recusar) NÃO se concedem a `authenticated`: quem as chama é o utente em casa,
-- sem sessão, através de uma Edge Function com a chave de serviço. Conceder-lhes
-- acesso direto deixaria qualquer pessoa com a chave pública abrir e assinar
-- consentimentos em nome de outro. Ver a nota no topo.
revoke all on function clinia.abrir_consentimento(text, inet, text) from public, anon, authenticated;
revoke all on function clinia.pedir_codigo_consentimento(text, inet, text) from public, anon, authenticated;
revoke all on function clinia.confirmar_codigo_consentimento(text, text, inet, text) from public, anon, authenticated;
revoke all on function clinia.assinar_consentimento(text, text, text, inet, text) from public, anon, authenticated;
revoke all on function clinia.recusar_consentimento(text, text, inet, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- E AO `service_role` CONCEDE-SE, EXPLICITAMENTE. É A ÚNICA COISA QUE FAZ O
-- CIRCUITO FUNCIONAR.
-- ---------------------------------------------------------------------------
-- O DEFEITO QUE ISTO CORRIGE, e que valeu a pena descobrir antes de instalar:
--
-- O `revoke all ... from public` acima tira a permissão a TODA A GENTE — e o
-- `public` num `revoke` significa «todos os papéis», não «o papel chamado
-- public». O `service_role` NUNCA tinha recebido uma concessão própria: vivia da
-- concessão implícita que o PostgreSQL dá ao criar a função.
--
-- Resultado: a Edge Function, que é o ÚNICO caminho para o utente assinar, não
-- conseguia chamar nenhuma destas funções. O erro seria
--
--   permission denied for function abrir_consentimento
--
-- e apareceria no ecrã do utente como «não consegui abrir o consentimento» — em
-- produção, com o utente à espera, e sem nada que apontasse para a causa.
--
-- A distinção que importa: o `service_role` NÃO é o papel público. A chave dele
-- vive no servidor, dentro da Edge Function, e nunca vai para o browser. Sem
-- esta concessão, o circuito está protegido e inútil ao mesmo tempo — a pior
-- combinação possível, porque os testes de segurança passam todos.
grant execute on function clinia.abrir_consentimento(text, inet, text) to service_role;
grant execute on function clinia.pedir_codigo_consentimento(text, inet, text) to service_role;
grant execute on function clinia.confirmar_codigo_consentimento(text, text, inet, text) to service_role;
grant execute on function clinia.assinar_consentimento(text, text, text, inet, text) to service_role;
grant execute on function clinia.recusar_consentimento(text, text, inet, text) to service_role;

-- AS FUNÇÕES AUXILIARES, essas, PODEM SER PÚBLICAS — e têm de ser.
--
-- O `hash_token_consentimento` é um SHA-256 puro: não revela nada que o
-- chamador já não tenha, e não dá acesso a nada. A Edge Function precisa dele
-- para procurar o pedido pelo token, e é calculado AQUI, e não em JavaScript,
-- para garantir que o hash é feito exatamente da mesma forma nos dois lados.
-- Uma diferença de codificação daria um token que nunca encontra o pedido, e o
-- erro apareceria como «link inválido» sem ninguém perceber porquê.
grant execute on function clinia.hash_token_consentimento(text) to anon, authenticated;
-- O `gerar_token_consentimento` NÃO se concede: gerar tokens é do servidor. Um
-- token gerado pelo browser não seria segredo nenhum.

-- ---------------------------------------------------------------------------
-- 15. VERIFICAÇÃO
-- ---------------------------------------------------------------------------
do $$
declare
  v_textos   integer;
  v_tabelas  integer;
begin
  select count(*) into v_textos from public.consentimento_textos;
  select count(*) into v_tabelas
    from information_schema.tables
   where table_schema = 'public'
     and table_name in ('consentimento_textos','consentimento_pedidos','consentimento_eventos');

  if v_tabelas <> 3 then
    raise exception 'Faltam tabelas do consentimento: % de 3.', v_tabelas;
  end if;

  if v_textos = 0 then
    raise notice 'AVISO: nao ha textos de consentimento. O circuito nao tem o que mostrar.';
  else
    raise notice 'Consentimento online pronto: % textos por omissao.', v_textos;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 0024_alergias_e_medicacao.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0024 — ALERGIAS, MEDICAÇÃO E O CÓDIGO COMUNICADO
-- ============================================================================
--
-- O QUE ESTA MIGRAÇÃO ACRESCENTA, E PORQUÊ
-- ============================================================================
--
-- 1. ALERGIAS ESTRUTURADAS
--
--    O clinIA guardava `utentes.alergias text[]` — uma lista de texto. «Penicilina»,
--    «Marisco», «AINE».
--
--    Isso não chega, e não é uma questão de arrumação: é DECISÃO CLÍNICA.
--    «Penicilina» não diz se foi um exantema ligeiro ou uma anafilaxia, e quem
--    vai prescrever precisa de saber. O sistema não perguntava.
--
--    E há uma distinção ainda mais fina, que se aprendeu a ver no DOCbase (que
--    guarda `ALERGIAINFOORIGEM`): **de onde veio a informação**. «O doente disse»
--    não é o mesmo que «confirmado em teste». Em segurança clínica, é a
--    diferença entre um dado e uma suspeita.
--
--    O campo `alergias text[]` FICA. Serve a linha rápida no cabeçalho da ficha,
--    que é onde a alergia tem de aparecer sempre, sem um JOIN. A tabela nova é o
--    detalhe por trás, e é ela a fonte para a decisão.
--
-- 2. MEDICAÇÃO ATIVA E HISTÓRICA
--
--    `utentes.medicacao_habitual text` tinha um defeito estrutural: **um campo de
--    texto não tem história.** Cada gravação apagava a anterior, e a pergunta que
--    interessa numa avaliação — «o que mudou desde a última consulta?» — não
--    tinha resposta.
--
--    A tabela nova guarda o que se toma agora E o que se tomou, com datas e
--    motivo de paragem. É o mesmo padrão da alergia: o que era texto passa a ser
--    registo.
--
-- 3. O CÓDIGO QUE O PROFISSIONAL COMUNICA
--
--    O circuito do consentimento guarda o código OTP em HASH e nunca em claro —
--    e está certo. Mas isso deixava um buraco: quando a clínica ainda não tem
--    serviço de email ligado (ou quando ele falha), a função responde ao utente
--    «peça à clínica para lhe comunicar o código», **e a clínica não tinha como
--    o ver**. O utente ficava sem forma de assinar, e a clínica sem forma de
--    ajudar.
--
--    `clinia.pedir_codigo_para_comunicar` fecha isso: um profissional
--    autenticado pede o código de um pedido da SUA clínica, e recebe-o para o
--    dizer ao utente ao telefone ou ao balcão. É assinatura avançada na mesma —
--    o utente continua a precisar de um código que só ele recebe.
--
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. OS TIPOS
-- ---------------------------------------------------------------------------
-- Enum e não texto livre: estes valores são usados em decisão, e um erro de
-- escrita num deles («anafilaxia» vs «anafiláctico») partiria uma consulta sem
-- dar erro. O DOCbase fazia isto com tabelas de catálogo — cinco tabelas para o
-- mesmo. Um enum resolve.

do $tipos$
begin
  if not exists (select 1 from pg_type where typname = 'alergia_gravidade') then
    create type public.alergia_gravidade as enum ('ligeira', 'moderada', 'grave', 'anafilaxia');
  end if;

  if not exists (select 1 from pg_type where typname = 'alergia_reacao') then
    create type public.alergia_reacao as enum (
      'cutanea', 'respiratoria', 'digestiva', 'cardiovascular',
      'neurologica', 'sistemica', 'outra');
  end if;

  /* A ORIGEM DA INFORMAÇÃO — a ideia que se aprendeu no DOCbase.
     Um dado clínico sem proveniência vale menos, e quem decide tem o direito de
     saber quanto vale. */
  if not exists (select 1 from pg_type where typname = 'alergia_origem') then
    create type public.alergia_origem as enum (
      'doente', 'familiar', 'processo', 'teste', 'profissional', 'desconhecida');
  end if;

  if not exists (select 1 from pg_type where typname = 'medicacao_motivo_fim') then
    create type public.medicacao_motivo_fim as enum (
      'concluido', 'suspenso', 'substituido', 'efeito_adverso', 'abandonou', 'outro');
  end if;
end $tipos$;

comment on type public.alergia_origem is
  'De onde veio a informacao da alergia. «O doente disse» nao e o mesmo que «confirmado em teste» — e quem decide tem o direito de saber a diferenca.';

-- ---------------------------------------------------------------------------
-- 2. ALERGIAS
-- ---------------------------------------------------------------------------
create table if not exists public.utente_alergias (
  id            uuid primary key default gen_random_uuid(),
  clinica_id    uuid not null references public.clinicas(id) on delete cascade,
  utente_id     uuid not null references public.utentes(id) on delete cascade,

  -- O que faz a reacao. Texto e nao catalogo: o nome de um farmaco, de um
  -- alimento ou de um material de penso nao cabem numa lista fechada, e uma
  -- lista incompleta obriga a inventar.
  substancia    text not null,

  reacao        text,
  tipo_reacao   public.alergia_reacao,
  gravidade     public.alergia_gravidade,
  origem        public.alergia_origem not null default 'desconhecida',

  -- Quando foi confirmada ou relatada. Nulo = nao se sabe quando.
  desde         date,

  ativa         boolean not null default true,
  notas         text,

  -- Quem registou. Sem isto, um erro de registo nao tem autor.
  registado_por uuid references public.perfis(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- Uma substancia vazia nao e uma alergia.
  constraint utente_alergias_substancia_util check (length(btrim(substancia)) >= 2),

  -- A GRAVIDADE NAO PODE CONTRADIZER A REACAO.
  --
  -- «Anafilaxia» e uma gravidade e tambem um desfecho; se a gravidade maxima
  -- esta marcada, o tipo de reacao tem de ser sistemico ou cardiovascular. Sem
  -- isto, a base de dados aceitaria «anafilaxia / cutanea», que e clinicamente
  -- incoerente, e alguem acreditariam nisso.
  constraint utente_alergias_anafilaxia_coerente check (
    gravidade is distinct from 'anafilaxia'
    or tipo_reacao is null
    or tipo_reacao in ('sistemica', 'cardiovascular', 'respiratoria')
  )
);

comment on table public.utente_alergias is
  'Alergias do utente, com gravidade, tipo de reacao e origem da informacao. O campo utentes.alergias (text[]) fica como resumo no cabecalho da ficha.';

create index if not exists idx_utente_alergias_utente
  on public.utente_alergias (utente_id) where ativa;

create unique index if not exists uq_utente_alergias_substancia
  on public.utente_alergias (utente_id, lower(btrim(substancia)));

-- ---------------------------------------------------------------------------
-- 3. MEDICAÇÃO
-- ---------------------------------------------------------------------------
create table if not exists public.utente_medicacao (
  id            uuid primary key default gen_random_uuid(),
  clinica_id    uuid not null references public.clinicas(id) on delete cascade,
  utente_id     uuid not null references public.utentes(id) on delete cascade,

  medicamento   text not null,
  dosagem       text,                       -- «500 mg», «1 comprimido»
  frequencia    text,                       -- «2x/dia», «ao deitar»

  inicio        date,
  fim           date,
  motivo_fim    public.medicacao_motivo_fim,
  motivo_fim_nota text,

  -- Quem prescreveu. Texto e nao referencia a profissionais: pode ser um medico
  -- de fora, e o utente traz a informacao numa receita em papel.
  prescritor    text,
  notas         text,

  registado_por uuid references public.perfis(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint utente_medicacao_nome_util check (length(btrim(medicamento)) >= 2),

  /* UMA MEDICAÇÃO TERMINADA TEM DE DIZER PORQUÊ.
     «Parou» sem motivo nao permite perceber se foi por melhoria ou por efeito
     adverso — e a diferenca importa para a proxima prescricao. */
  constraint utente_medicacao_fim_explica check (fim is null or motivo_fim is not null),

  constraint utente_medicacao_datas_coerentes check (fim is null or inicio is null or fim >= inicio)
);

comment on table public.utente_medicacao is
  'Medicacao do utente, ativa e historica. Responde a «o que mudou desde a ultima consulta?» — pergunta que um campo de texto nao sabia responder.';

create index if not exists idx_utente_medicacao_utente
  on public.utente_medicacao (utente_id, fim nulls first);

create index if not exists idx_utente_medicacao_ativa
  on public.utente_medicacao (utente_id) where fim is null;

-- ---------------------------------------------------------------------------
-- 4. AS VISTAS
-- ---------------------------------------------------------------------------
-- A vista que o ecra usa: uma linha por utente, com as alergias juntas para o
-- cabecalho. `security_invoker` para o RLS das tabelas de baixo continuar a
-- mandar — sem isto, uma vista e uma porta lateral que ignora as politicas.

create or replace view public.vw_utente_alergias as
  select a.id, a.clinica_id, a.utente_id, a.substancia, a.reacao,
         a.tipo_reacao::text as tipo_reacao,
         a.gravidade::text   as gravidade,
         a.origem::text      as origem,
         a.desde, a.ativa, a.notas,
         u.nome as utente_nome
    from public.utente_alergias a
    join public.utentes u on u.id = a.utente_id;

alter view public.vw_utente_alergias set (security_invoker = true);

comment on view public.vw_utente_alergias is
  'Alergias com os enums como texto, para o ecra nao ter de os traduzir.';

/* A PERGUNTA QUE INTERESSA: o que mudou desde a ultima consulta?
 *
 * Mostra só a medicação ATIVA, com a data de inicio, para o profissional ver
 * numa linha o que o doente toma agora. A histórica fica na tabela. */
create or replace view public.vw_utente_medicacao_ativa as
  select m.id, m.clinica_id, m.utente_id, m.medicamento, m.dosagem, m.frequencia,
         m.inicio, m.prescritor, m.notas,
         u.nome as utente_nome
    from public.utente_medicacao m
    join public.utentes u on u.id = m.utente_id
   where m.fim is null;

alter view public.vw_utente_medicacao_ativa set (security_invoker = true);

-- ---------------------------------------------------------------------------
-- 5. SEGURANÇA
-- ---------------------------------------------------------------------------
alter table public.utente_alergias   enable row level security;
alter table public.utente_medicacao  enable row level security;

-- Quem é da clínica vê e escreve o que é da clínica. As alergias e a medicação
-- são dados clínicos: quem os altera tem de ser clínico, não administrativo.
drop policy if exists utente_alergias_ler on public.utente_alergias;
create policy utente_alergias_ler on public.utente_alergias
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id());

drop policy if exists utente_alergias_escrever on public.utente_alergias;
create policy utente_alergias_escrever on public.utente_alergias
  for insert to authenticated
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

drop policy if exists utente_alergias_alterar on public.utente_alergias;
create policy utente_alergias_alterar on public.utente_alergias
  for update to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
  with check (clinica_id = clinia.current_clinica_id());

/* APAGAR UMA ALERGIA É UM ATO CLÍNICO, e por isso é permitido a um clínico —
 * mas não é a forma normal de a retirar. A forma normal é `ativa = false`:
 * uma alergia que deixou de ser verdade é um dado clínico, e apagá-la perde a
 * informação de que existiu. A política deixa apagar para corrigir um erro de
 * registo; o ecrã usa `ativa`. */
drop policy if exists utente_alergias_apagar on public.utente_alergias;
create policy utente_alergias_apagar on public.utente_alergias
  for delete to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

drop policy if exists utente_medicacao_ler on public.utente_medicacao;
create policy utente_medicacao_ler on public.utente_medicacao
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id());

drop policy if exists utente_medicacao_escrever on public.utente_medicacao;
create policy utente_medicacao_escrever on public.utente_medicacao
  for insert to authenticated
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_clinico());

drop policy if exists utente_medicacao_alterar on public.utente_medicacao;
create policy utente_medicacao_alterar on public.utente_medicacao
  for update to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_clinico())
  with check (clinica_id = clinia.current_clinica_id());

grant select, insert, update, delete on public.utente_alergias  to authenticated;
grant select, insert, update, delete on public.utente_medicacao to authenticated;
grant select on public.vw_utente_alergias        to authenticated;
grant select on public.vw_utente_medicacao_ativa to authenticated;

-- ---------------------------------------------------------------------------
-- 6. O CÓDIGO QUE O PROFISSIONAL COMUNICA
-- ---------------------------------------------------------------------------
-- PEDIDO PELO PROFISSIONAL, NÃO PELO UTENTE.
--
-- O `pedir_codigo_consentimento` é chamado com um TOKEN, pelo utente em casa,
-- sem sessão. Este é chamado com o ID DE UM PEDIDO, por um profissional
-- autenticado, e só funciona para pedidos da clínica dele.
--
-- São dois caminhos para o mesmo código, e a diferença é QUEM PEDE. Manter os
-- dois na mesma função seria dar ao utente a possibilidade de pedir o código de
-- outro — que é exatamente o que a assinatura avançada existe para impedir.
create or replace function clinia.pedir_codigo_para_comunicar(p_pedido uuid)
returns table (codigo text, utente_nome text, canal text, expira_em timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
  v_nome   text;
  v_codigo text;
  v_expira timestamptz;
begin
  /* Sem sessão de clínica não há nada a fazer. A Edge Function usa a chave de
     serviço e não passa por aqui; um utilizador autenticado passa. */
  if not clinia.e_clinico() then
    raise exception 'So um profissional da clinica pode pedir o codigo para comunicar.';
  end if;

  select * into v_pedido
    from public.consentimento_pedidos p
   where p.id = p_pedido
     and p.clinica_id = clinia.current_clinica_id();

  if v_pedido.id is null then
    raise exception 'Pedido de consentimento nao encontrado nesta clinica.';
  end if;

  if v_pedido.estado in ('assinado', 'recusado', 'cancelado', 'expirado') then
    raise exception 'Este pedido ja terminou (%). Nao ha codigo a comunicar.', v_pedido.estado;
  end if;

  if v_pedido.expira_em < now() then
    raise exception 'Este pedido expirou. Cria um novo.';
  end if;

  if v_pedido.tentativas_otp >= 5 then
    raise exception 'Demasiadas tentativas neste pedido. Cria um novo.';
  end if;

  v_codigo := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  v_expira := now() + interval '10 minutes';

  update public.consentimento_pedidos
     set otp_hash       = clinia.hash_token_consentimento(v_codigo),
         otp_expira_em  = v_expira,
         otp_enviado_em = now(),
         estado         = 'otp_enviado',
         tentativas_otp = tentativas_otp + 1
   where id = v_pedido.id;

  select u.nome into v_nome from public.utentes u where u.id = v_pedido.utente_id;

  /* O registo diz QUE FOI O PROFISSIONAL a pedir, e não o utente. A prova de
     quem assinou depende de saber por que caminho o código chegou lá. */
  insert into public.consentimento_eventos (pedido_id, tipo, detalhe)
  values (v_pedido.id, 'otp_pedido_pela_clinica',
          jsonb_build_object('destino', v_pedido.destino_mascarado,
                             'canal', v_pedido.canal::text));

  return query select v_codigo, v_nome, v_pedido.canal::text, v_expira;
end $$;

comment on function clinia.pedir_codigo_para_comunicar(uuid) is
  'Um profissional da clinica pede o codigo OTP para o comunicar ao utente (telefone ou balcao). E o caminho que permite o consentimento funcionar sem servico de email ligado.';

/* A PERMISSÃO É O CONTRÁRIO DA DO CIRCUITO PÚBLICO.
 *
 * As funções que o utente usa (abrir, pedir código, assinar) estão REVOGADAS de
 * `authenticated`, porque quem as chama é a Edge Function com a chave de
 * serviço. Esta é o oposto: quem a chama é o profissional, com sessão, e por
 * isso é a `authenticated` que se concede — e ao `anon` se revoga.
 *
 * Conceder esta a `anon` seria dar a qualquer pessoa com o link o código do
 * utente. É a distinção mais importante deste bloco. */
revoke all on function clinia.pedir_codigo_para_comunicar(uuid) from public, anon;
grant execute on function clinia.pedir_codigo_para_comunicar(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. NÃO SE CRIA ECRÃ NOVO — E É DELIBERADO
-- ---------------------------------------------------------------------------
-- A tentação era acrescentar dois ecrãs, `alergias` e `medicacao`, à tabela
-- `ecras`. Não se faz, por duas razões:
--
-- 1. NÃO EXISTEM NO CLIENTE. O `codigo` de um ecrã tem de coincidir com a ROTA
--    do cliente. Um ecrã na base de dados sem rota correspondente fica invisível
--    no menu — e `tools/testar_codigos_de_ecra.mjs` existe precisamente para
--    apanhar essa divergência, porque já aconteceu três vezes. A primeira versão
--    desta migração inventou `rota` e `icone`, que não são colunas de `ecras`.
--
-- 2. NÃO FAZEM SENTIDO COMO ECRÃ. Alergias e medicação não são destinos: são
--    dados de UM utente, e pertencem à ficha dele — que já tem ecrã (`utentes`)
--    — ao lado do resto da história clínica, e não num sítio separado a que o
--    profissional tem de se lembrar de ir.
--
-- Um ecrã de «Alergias» no menu daria a lista das alergias de todos os doentes,
-- que não é uma coisa que alguém queira ver.
--
-- O que esta migração acrescenta é a POSSIBILIDADE de os ecrãs existentes os
-- mostrarem: tabelas, vistas e permissões. A interface trata do resto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 8. O ECRÃ DO CÓDIGO
-- ---------------------------------------------------------------------------
-- Ao contrário das alergias e da medicação — que pertencem à ficha do utente e
-- não têm ecrã próprio — este É um destino: o profissional vai lá para pedir o
-- código. Precisa de entrada no menu e de visibilidade por perfil.
--
-- O `codigo` tem de coincidir com a ROTA registada no cliente, e a rota é
-- `codigo_consentimento` (ver `web/src/ecras/consentimento-codigo.js` e a
-- tabela de rotas em `web/src/app.js`). Sem isso o ecrã existe na base de dados
-- e não aparece no menu — que é o defeito que a migração 0022 corrigiu, e que
-- `tools/testar_codigos_de_ecra.mjs` agora apanha.
--
-- QUEM VÊ: SÓ QUEM PODE PEDIR. E ISSO EXCLUI A RECEÇÃO E A GESTÃO.
--
-- A primeira versão desta lista incluía a receção, com um raciocínio que parecia
-- bom: «é a receção que está ao balcão e ao telefone». **Estava errado, e o teste
-- provou-o** — a receção vê o ecrã e recebe «Só um profissional da clínica pode
-- pedir o código para comunicar».
--
-- **Um ecrã que promete o que não cumpre é pior do que não existir.** Quem o vê
-- no menu e não o consegue usar conclui que o programa está avariado.
--
-- A decisão, e a razão:
--
-- O código é o SEGUNDO FACTOR. É ele que prova que quem assina é o utente, e não
-- outra pessoa com o link. Quem o pode pedir tem, na prática, o poder de o
-- comunicar a quem lho pedir — e quem o receber ao telefone assina em nome do
-- utente. Por isso só o pode pedir quem já tem responsabilidade clínica sobre
-- ele: `clinia.e_clinico()`.
--
-- A consequência prática está prevista: o profissional comunica o código ao
-- utente **enquanto ele está à frente dele**, ou ao telefone depois de o
-- reconhecer. É assim que se faz na maior parte das clínicas, e é a forma que
-- mantém a assinatura avançada com o valor que tem.
--
-- A `gestao` também não entra, pela mesma razão: é financeira, não é clínica.
--
-- O `codigo` tem de coincidir com a ROTA registada no cliente. Sem isso o ecrã
-- existe na base de dados e não aparece no menu — o defeito que a migração 0022
-- corrigiu, e que `tools/testar_codigos_de_ecra.mjs` apanha.
/*
 * UMA ATUALIZAÇÃO, E NÃO UM «DO NOTHING».
 *
 * Com `on conflict do nothing`, uma instalação que já tivesse corrido a versão
 * anterior desta migração ficava com a lista ANTIGA — com a receção lá dentro e
 * o ecrã a prometer o que não cumpre. **Uma correção que não chega a quem já
 * instalou não é uma correção.**
 *
 * Aqui atualiza-se a visibilidade. É seguro por construção: este ecrã é novo
 * nesta migração, e ninguém teve tempo de o configurar de outra maneira. Se
 * alguém o tiver feito à mão, esta linha repõe o que a migração decidiu — e é o
 * comportamento certo, porque a lista tem de ser coerente com a função.
 */
insert into public.ecras (codigo, nome, grupo, ordem, area, visivel_em, obrigatorio)
values ('codigo_consentimento', 'Código do consentimento', 'Processo clínico', 65, 'clinica',
        '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro}',
        false)
on conflict (codigo) do update
  set visivel_em = excluded.visivel_em,
      nome       = excluded.nome,
      grupo      = excluded.grupo;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Esperado: 2 tabelas novas, 4 tipos, 2 vistas.
--
--   select count(*) from public.utente_alergias;
--   select count(*) from public.utente_medicacao;
--   select typname from pg_type where typname like 'alergia%' or typname = 'medicacao_motivo_fim';
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0025_autorizacao_consentimento.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0025 — AUTORIZAÇÃO EM DUAS FUNÇÕES DO CONSENTIMENTO
-- ============================================================================
--
-- O DEFEITO QUE ISTO CORRIGE
-- ============================================================================
--
-- Duas funções da migração 0023 são `security definer` — correm com os
-- privilégios do dono, e por isso AS POLÍTICAS DE RLS DAS TABELAS DE BAIXO NÃO
-- AS TRAVAM — e não verificam QUEM as chama:
--
--   clinia.pedir_consentimento(utente, texto, canal, destino, episodio)
--   clinia.cancelar_pedido_consentimento(pedido)
--
-- As duas estão concedidas a `authenticated`. Consequência medida, com um perfil
-- de receção a sério (`e_clinico() = false`):
--
--     criou o pedido: true
--
-- **A autorização estava a depender do ECRÃ, e não da base de dados.** O ecrã só
-- mostra o botão a quem pode — mas quem chamar a função diretamente, pela API,
-- com o seu próprio token, passa por cima do ecrã. E o ecrã não é uma barreira:
-- é uma sugestão.
--
-- Pior no `cancelar`: ele atualiza **por id, sem verificar a clínica**. Qualquer
-- pessoa autenticada em QUALQUER clínica podia cancelar o pedido de consentimento
-- de outra. A única coisa que o travava era o id ser um UUID opaco.
--
-- ============================================================================
-- PORQUE UMA MIGRAÇÃO NOVA, E NÃO UMA CORREÇÃO NA 0023
-- ============================================================================
--
-- A 0023 está num ficheiro que esta máquina recusa escrever (EPERM — o mesmo
-- bloqueio que já apareceu no `consentimento.js` e no `index.ts` da Edge
-- Function). E, mesmo que fosse gravável, **reescrever uma migração já publicada
-- é a forma errada de corrigir**: quem já a correu não a volta a correr, e a
-- correção não lhe chega.
--
-- Uma migração nova chega a todos: a quem instala agora, e a quem já instalou.
--
-- ============================================================================
-- A REGRA QUE FALTAVA
-- ============================================================================
--
-- Pedir e cancelar um consentimento é um ato **clínico**: quem o faz decide que
-- o utente vai ser informado e que vai assinar. A receção marca consultas; não
-- decide sobre consentimento informado. A gestão trata do dinheiro; também não.
--
-- E há uma razão prática, além da formal: o pedido gera um **link que dá acesso
-- ao processo clínico do utente** e um código que assina em nome dele. Quem
-- emite isso tem de responder por isso.
--
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PEDIR CONSENTIMENTO — com a guarda que faltava
-- ---------------------------------------------------------------------------
create or replace function clinia.pedir_consentimento(
  p_utente      uuid,
  p_texto_id    uuid,
  p_canal       public.consentimento_canal,
  p_destino     text,
  p_episodio    uuid default null
)
returns table (pedido_id uuid, token text, expira_em timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid;
  v_token   text;
  v_pedido  uuid;
  v_expira  timestamptz;
  v_aberto  integer;
begin
  /* -------------------------------------------------------------------------
     QUEM PEDE TEM DE SER CLÍNICO, E O UTENTE TEM DE SER DESTA CLÍNICA.
     -------------------------------------------------------------------------
     A primeira verificação é a que faltava. A segunda evita que um clínico de
     uma clínica peça consentimento a um utente de outra — que a `security
     definer` também deixava passar, porque não há RLS que a trave. */
  if not clinia.e_clinico() then
    raise exception
      'So um profissional da clinica pode pedir um consentimento. A rececao marca consultas; nao decide sobre consentimento informado.';
  end if;

  select u.clinica_id into v_clinica from public.utentes u where u.id = p_utente;

  if v_clinica is null then
    raise exception 'O utente % nao existe.', p_utente;
  end if;

  if v_clinica <> clinia.current_clinica_id() then
    raise exception 'Esse utente nao e desta clinica.';
  end if;

  if not exists (select 1 from public.consentimento_textos t where t.id = p_texto_id and t.ativo) then
    raise exception 'O texto de consentimento % nao existe ou esta inativo.', p_texto_id;
  end if;

  if p_canal <> 'balcao' and (p_destino is null or length(btrim(p_destino)) = 0) then
    raise exception 'Um pedido por % precisa de um destino (email ou telefone).', p_canal;
  end if;

  /* Um pedido em aberto por texto: pedir o mesmo consentimento duas vezes cria
     dois links validos, e o utente assina o que abrir primeiro. O segundo fica
     pendente para sempre e a ficha mostra um estado que ninguem percebe. */
  select count(*) into v_aberto
    from public.consentimento_pedidos p
   where p.utente_id = p_utente
     and p.texto_id = p_texto_id
     and p.estado in ('pedido', 'enviado', 'visto', 'otp_enviado', 'otp_confirmado');

  if v_aberto > 0 then
    raise exception
      'Ja existe um pedido em aberto para este consentimento. Cancela-o antes de criar outro.';
  end if;

  v_token  := clinia.gerar_token_consentimento();
  v_expira := now() + interval '72 hours';

  insert into public.consentimento_pedidos
    (clinica_id, utente_id, episodio_id, texto_id, canal, destino, destino_mascarado, token_hash, expira_em, criado_por)
  values
    (v_clinica, p_utente, p_episodio, p_texto_id, p_canal,
     case when p_canal = 'balcao' then null else p_destino end,
     clinia.mascarar_destino(p_destino),
     clinia.hash_token_consentimento(v_token), v_expira, auth.uid())
  returning id into v_pedido;

  insert into public.consentimento_eventos (pedido_id, tipo, detalhe)
  values (v_pedido, 'pedido_criado',
          jsonb_build_object('canal', p_canal::text, 'por', auth.uid()));

  return query select v_pedido, v_token, v_expira;
end $$;

comment on function clinia.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid) is
  'Cria um pedido de consentimento. Exige um profissional clinico, e que o utente seja desta clinica — a autorizacao nao pode depender do ecra.';

-- ---------------------------------------------------------------------------
-- 2. CANCELAR — com a guarda que faltava, e a clínica verificada
-- ---------------------------------------------------------------------------
create or replace function clinia.cancelar_pedido_consentimento(p_pedido uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido public.consentimento_pedidos;
begin
  if not clinia.e_clinico() then
    raise exception 'So um profissional da clinica pode cancelar um pedido de consentimento.';
  end if;

  /* -------------------------------------------------------------------------
     A CLÍNICA É VERIFICADA, E ISSO É A CORREÇÃO MAIS IMPORTANTE DESTA FUNÇÃO.
     -------------------------------------------------------------------------
     A versão anterior atualizava direto por `id`. Com a chave de serviço não há
     RLS que a trave, mas com um utilizador autenticado uma função `security
     definer` também não é travada: quem tivesse um id conseguia cancelar o
     pedido de OUTRA clínica.

     Aqui o pedido é lido primeiro, e recusa-se se não for desta clínica. */
  select * into v_pedido
    from public.consentimento_pedidos p
   where p.id = p_pedido
     and p.clinica_id = clinia.current_clinica_id();

  if v_pedido.id is null then
    raise exception 'Pedido de consentimento nao encontrado nesta clinica.';
  end if;

  update public.consentimento_pedidos
     set estado = 'cancelado', destino = null
   where id = p_pedido
     and estado in ('pedido','enviado','visto','otp_enviado','otp_confirmado');

  insert into public.consentimento_eventos (pedido_id, tipo, detalhe)
  values (p_pedido, 'cancelado', jsonb_build_object('por', auth.uid()));
end $$;

comment on function clinia.cancelar_pedido_consentimento(uuid) is
  'Cancela um pedido. Exige um profissional clinico E que o pedido seja da clinica de quem cancela.';

-- ---------------------------------------------------------------------------
-- 3. OS PRIVILÉGIOS
-- ---------------------------------------------------------------------------
-- Continuam concedidas a `authenticated` — quem as chama é o profissional, com
-- sessão — mas agora a função verifica. A diferença é entre «só quem tem
-- permissão chega aqui» e «só quem tem permissão consegue fazer isto».
grant execute on function clinia.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid) to authenticated;
grant execute on function clinia.cancelar_pedido_consentimento(uuid) to authenticated;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Com um perfil de RECEÇÃO (e_clinico() falso), as duas chamadas têm de recusar:
--
--   select * from clinia.pedir_consentimento(<utente>, <texto>, 'email', 'a@b.pt', null);
--   select clinia.cancelar_pedido_consentimento(<pedido>);
--
-- Esperado nas duas: «So um profissional da clinica ...».
--
-- E com um perfil clínico de OUTRA clínica, o cancelar tem de dizer
-- «nao encontrado nesta clinica» — e nao cancelar nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0026_permissoes_de_sequencias.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0026 — A PERMISSÃO QUE FALTAVA NA SEQUÊNCIA
-- ============================================================================
--
-- O DEFEITO
-- ============================================================================
--
-- A migração 0003 cria `public.utente_numero_seq` e usa-a como valor por omissão
-- de `utentes.numero_utente`:
--
--     create sequence if not exists public.utente_numero_seq start 1;
--     numero_utente integer not null default nextval('public.utente_numero_seq'),
--
-- **E nunca concede `usage` nessa sequência a ninguém.**
--
-- Medido, com um profissional clínico autenticado a tentar criar um utente:
--
--     permission denied for sequence utente_numero_seq
--
-- **E isto trava a escrita na PRÓPRIA clínica.** Não é uma questão de
-- isolamento: ninguém cria um utente, em clínica nenhuma.
--
-- E o mesmo na clínica errada, e sem contexto — o que é pior do que parecia,
-- porque significa que a recusa vinha da sequência e não do RLS. Um teste que
-- verificasse «não consegui escrever na clínica errada» passaria **pela razão
-- errada**: não estava a medir o RLS, estava a medir uma permissão em falta.
--
-- ============================================================================
-- PORQUE É QUE ISTO PODE NÃO APARECER
-- ============================================================================
--
-- O Supabase cria os seus papéis com `ALTER DEFAULT PRIVILEGES`, e é possível que
-- o `authenticated` receba `usage` em sequências novas por essa via — depende de
-- como o projeto foi criado, e não está escrito em lado nenhum deste repositório.
--
-- Ou seja: **isto pode funcionar numa instalação e falhar noutra, sem nada o
-- dizer.** É a pior forma de depender de alguma coisa.
--
-- A concessão explícita elimina a dúvida. Um `grant` que já era verdade não faz
-- mal nenhum; um `grant` que faltava é a diferença entre funcionar e não.
--
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A CONCESSÃO
-- ---------------------------------------------------------------------------
-- `usage` é o que permite chamar `nextval` e `currval`. Não é `select` nem
-- `update`: quem cria um utente precisa de tirar o número seguinte, e de nada
-- mais. Conceder o mínimo é o que mantém o privilégio legível.
do $$
begin
  if exists (
    select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'utente_numero_seq'
       and c.relkind = 'S'
  ) then
    grant usage on sequence public.utente_numero_seq to authenticated;
    grant usage on sequence public.utente_numero_seq to service_role;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- E TODAS AS OUTRAS SEQUÊNCIAS, PARA O MESMO DEFEITO NÃO VOLTAR
-- ---------------------------------------------------------------------------
-- O defeito não é desta sequência em particular: é de o projeto criar sequências
-- e não as conceder. Se outra migração criar mais alguma, tem de ser apanhada
-- sem ninguém se lembrar.
--
-- Isto corre a cada instalação, e concede o que já devia estar concedido. É
-- idempotente: conceder duas vezes é conceder uma.
do $$
declare
  v_seq record;
  v_n   integer := 0;
begin
  for v_seq in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'S'
  loop
    execute format('grant usage on sequence public.%I to authenticated', v_seq.relname);
    execute format('grant usage on sequence public.%I to service_role', v_seq.relname);
    v_n := v_n + 1;
  end loop;

  if v_n > 0 then
    raise notice 'Permissao de uso concedida em % sequencia(s) a authenticated.', v_n;
  end if;
end $$;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Depois desta migração, com um profissional autenticado:
--
--   insert into public.utentes (clinica_id, nome, tipo) values (<clinica>, 'Teste', 'adulto');
--
-- Tem de FUNCIONAR na clínica dele. E tem de ser RECUSADO com
-- «new row violates row-level security policy» na clínica de outro — e é essa a
-- diferença que importa: antes desta migração, as duas davam «permission denied
-- for sequence», e a segunda recusava pela razão errada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0027_auditoria_nao_depende_da_sequencia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0027 — A AUDITORIA NÃO DEPENDE DA SEQUÊNCIA
-- ============================================================================
--
-- O QUE ESTA MIGRAÇÃO CORRIGE
-- ============================================================================
--
-- A migração 0015 fecha a escrita direta em `audit_log` e explica porquê num
-- comentário:
--
--     «A política de inserção em audit_log é with check (true), e existe grant de
--      insert para authenticated. Qualquer utilizador autenticado — mesmo sem
--      perfil válido — pode escrever registos de auditoria com a clínica que
--      quiser. **Hoje só falha por acidente: a sequência audit_log_id_seq não tem
--      grant**, e o insert rebenta antes de chegar à política.»
--
-- O diagnóstico estava certo e a correção foi feita: `revoke insert, update,
-- delete on public.audit_log from authenticated`. **Mas o comentário ficou.**
--
-- E o comentário passou a ser falso e perigoso, por duas razões:
--
--   1. **A proteção deixou de ser acidental.** Depois do `revoke` na tabela,
--      quem trava a escrita é a permissão da TABELA — medido:
--
--          audit_log   select=true   insert=false   update=false
--          insert direto  →  permission denied for table audit_log
--
--   2. **A migração 0026 concedeu `usage` na sequência do `audit_log`** ao
--      `authenticated`, ao conceder a TODAS as sequências de `public`. Isso foi
--      deliberado e está certo — a sequência já não é a barreira, e uma barreira
--      acidental não é uma barreira.
--
-- Quem ler o comentário da 0015 sem ler o resto conclui que a auditoria está
-- protegida por um acidente de permissões, e que basta um `grant` para a abrir.
-- **Não está, e não basta.** Mas um comentário errado num ficheiro de segurança
-- é a forma mais fácil de alguém «corrigir» o que não está partido.
--
-- ============================================================================
-- O QUE SE FAZ AQUI
-- ============================================================================
--
-- 1. Diz-se a verdade no sítio certo: um comentário na TABELA, que é onde quem
--    lê o esquema procura.
--
-- 2. Fecha-se a sequência explicitamente, para que a proteção não dependa de a
--    sequência estar concedida ou não. A barreira passa a ser a permissão da
--    tabela, e mais nada — que é uma barreira deliberada.
--
-- 3. Confirma-se que o caminho LEGÍTIMO continua a funcionar. `clinia.auditar()`
--    é um gatilho `security definer` e corre como dono: não depende de
--    `authenticated`, e tem de continuar a registar. Fechar a porta sem testar a
--    fechadura é como se faz uma auditoria que deixa de auditar sem ninguém dar
--    por isso.
--
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. A VERDADE, ONDE SE LÊ
-- ---------------------------------------------------------------------------
comment on table public.audit_log is
  'Registo de auditoria append-only (RGPD art. 30). A escrita direta esta FECHADA por duas vias deliberadas: `revoke insert, update, delete ... from authenticated` (migracao 0015) e a ausencia de grant na sequencia. O unico caminho legitimo e a funcao clinia.auditar(), que e um gatilho `security definer` e corre como dono. Nenhum utilizador, nem administrador, insere ou altera diretamente.';

comment on column public.audit_log.id is
  'Sequencia `audit_log_id_seq`. Sem `usage` para `authenticated`, de proposito: a sequencia nao e a barreira (a barreira e a permissao da tabela), mas nao ha razao para a conceder.';

-- ---------------------------------------------------------------------------
-- 2. A SEQUÊNCIA, FECHADA DE PROPÓSITO
-- ---------------------------------------------------------------------------
-- A 0026 concedeu `usage` a todas as sequências, e está certo para as que a
-- aplicação usa (`utente_numero_seq`, `episodio_numero_seq`, …). Esta não é uma
-- delas: quem escreve auditoria é o gatilho, que corre como dono.
--
-- A revogação torna isto explícito. Uma barreira que se sabe onde está vale mais
-- do que uma que se descobriu por acidente.
do $$
begin
  if exists (
    select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'audit_log_id_seq' and c.relkind = 'S'
  ) then
    revoke usage on sequence public.audit_log_id_seq from authenticated;
    revoke usage on sequence public.audit_log_id_seq from anon;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. AS OUTRAS SEQUÊNCIAS CONTINUAM CONCEDIDAS — E É DE PROPÓSITO
-- ---------------------------------------------------------------------------
-- `utente_numero_seq`, `episodio_numero_seq`, `prescricao_numero_seq` e
-- `requisicao_numero_seq` são usadas por `default` de colunas que a aplicação
-- insere. Sem `usage`, criar um utente, um episódio, uma prescrição ou uma
-- requisição falha — e falha na PRÓPRIA clínica, que foi o defeito 78.
--
-- A 0026 concede-as. Esta migração não lhes toca. A distinção que fica:
--
--   · sequências de colunas que a aplicação insere  → concedidas
--   · sequências de tabelas que só o dono escreve   → fechadas
--
-- ---------------------------------------------------------------------------
-- 4. E A AUDITORIA CONTINUA A REGISTAR?
-- ---------------------------------------------------------------------------
-- O gatilho `clinia.auditar()` é `security definer`. A revogação da sequência
-- não o afeta: ele corre como dono e usa a sequência como dono.
--
-- Verificado no teste, e não aqui: `tools/testar_partes.mjs` confirma que criar
-- um utente produz um evento de auditoria. Um teste que só confirma que a
-- escrita direta é recusada deixaria passar uma auditoria que deixou de
-- auditar — que é o pior desfecho possível para uma auditoria.

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Com um utilizador autenticado:
--
--   insert into public.audit_log (clinica_id) values (<clinica>);
--     → permission denied for table audit_log
--
-- E criar um utente tem de continuar a produzir um evento:
--
--   select count(*) from public.audit_log;   -- antes
--   insert into public.utentes (...) ...;    -- a ação
--   select count(*) from public.audit_log;   -- tem de ter aumentado
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0028_textos_de_consentimento_por_clinica.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0028 — OS TEXTOS DE CONSENTIMENTO SÃO DE UMA CLÍNICA
-- ============================================================================
--
-- O DEFEITO
-- ============================================================================
--
-- Encontrado por um auditor externo, e confirmado ao medir. A tabela
-- `consentimento_textos` guarda o TEXTO que o utente lê e assina — e não tinha
-- `clinica_id`. As duas consequências, medidas:
--
--   1. A política de leitura era `using (true)`:
--
--          create policy consentimento_textos_leitura ... using (true);
--
--      **Qualquer utilizador autenticado lê os textos de todas as clínicas.**
--      Não é um catálogo como o CID: é o documento jurídico que cada clínica
--      decidiu usar. Uma clínica não tem nada que ler o consentimento redigido
--      por outra.
--
--   2. A chave única era `unique (codigo, versao)` — GLOBAL:
--
--          constraint consentimento_textos_versao_unica unique (codigo, versao)
--
--      Se a clínica A criar o seu `tratamento/v1`, **a clínica B fica impedida
--      de criar o dela.** A segunda clínica a instalar-se bate numa restrição
--      causada pela primeira — um defeito que só aparece quando há dois clientes.
--
--   3. E a política de escrita, `with check (clinia.e_admin())`, também estava
--      incompleta: `e_admin()` diz «é administrador ou gestão», **sem verificar
--      de que clínica**. Um administrador da clínica A podia inserir um texto
--      marcado como sendo da clínica A — e, sem `clinica_id`, tudo era de todos.
--
-- ============================================================================
-- O DESENHO, E PORQUE É ESTE
-- ============================================================================
--
-- `clinica_id null` = TEXTO PARTILHADO, o modelo que o sistema propõe.
--
-- Os textos que a migração 0023 semeia — o consentimento informado para
-- tratamento, o de dados de saúde, o RGPD — são modelos genéricos, escritos para
-- toda a gente. Marcá-los como de uma clínica seria errado: eles existiam antes
-- de haver clínicas.
--
-- Assim:
--
--   · `clinica_id is null`  → o modelo partilhado. Toda a gente lê.
--   · `clinica_id = X`      → o texto da clínica X. Só a X lê.
--
-- E uma clínica que queira o seu próprio texto cria uma versão nova com o
-- `clinica_id` dela. O modelo partilhado fica como estava — que é o que faz
-- sentido, porque **um texto já assinado não pode mudar**: as assinaturas feitas
-- contra o modelo partilhado continuam a apontar para ele.
--
-- ============================================================================
-- O QUE ESTA MIGRAÇÃO NÃO FAZ
-- ============================================================================
--
-- Não apaga nem reescreve um único texto. Os que existem ficam com
-- `clinica_id = null`, que é exatamente o que eles são: partilhados. Uma
-- migração que «arruma» dados jurídicos é uma migração que altera o que alguém
-- assinou.
--
-- E não obriga ninguém a ter `clinica_id`. O `null` é uma escolha com
-- significado, não um campo por preencher.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. A COLUNA
-- ---------------------------------------------------------------------------
alter table public.consentimento_textos
  add column if not exists clinica_id uuid references public.clinicas(id) on delete cascade;

comment on column public.consentimento_textos.clinica_id is
  'NULL = texto PARTILHADO (o modelo que o sistema propoe, lido por todas as clinicas). Preenchido = texto DAQUELA clinica. Uma versao nova da clinica nao altera o modelo partilhado, porque um texto ja assinado nao pode mudar.';

/* ---------------------------------------------------------------------------
   2. A CHAVE ÚNICA, AGORA POR CLÍNICA
   ---------------------------------------------------------------------------
   A restrição antiga `unique (codigo, versao)` sai. Se ficasse, a clínica B não
   conseguia criar o seu `tratamento/v1` porque a clínica A já o tinha criado —
   que é o defeito 2 descrito acima.

   A SUBSTITUTA SÃO DOIS ÍNDICES, E FOI PRECISO TENTAR TRÊS VEZES PARA LÁ CHEGAR.

   Em SQL, dois `null` **não são iguais**. Isso dá a propriedade que se quer — a
   clínica A pode ter o seu `tratamento/v1` mesmo que exista o partilhado, porque
   `('uuid-da-A', 'tratamento', 'v1')` e `(null, 'tratamento', 'v1')` são linhas
   diferentes para um índice — mas não resolve a unicidade DOS PARTILHADOS.

   As tentativas, e porque falharam cada uma:

     1. `unique (codigo, versao)`, a antiga. Impede a clínica B de ter o seu
        `tratamento/v1` porque a A já o criou. É o defeito que se corrige.
     2. `unique (clinica_id, codigo, versao)`. **O `on conflict (codigo, versao)`
        da migração 0023 não consegue inferir este índice**: a inferência exige
        que as colunas do alvo sejam as PRIMEIRAS do índice, e `clinica_id` está
        à frente. Falha com «there is no unique or exclusion constraint matching
        the ON CONFLICT specification». E acrescentar `clinica_id` ao `on
        conflict` da 0023 obrigaria a mexer numa migração já corrida — **uma
        migração que obriga a reescrever uma anterior é pior do que o defeito que
        corrige.**
     3. `coalesce(clinica_id, <sentinela>)`. Muda a expressão, e o alvo do
        `on conflict` volta a não coincidir. Mesmo problema.

   O que fica, e porque funciona:

     · **Índice parcial nas PARTILHADAS** — `unique (codigo, versao) where
       clinica_id is null`. Garante um só modelo partilhado por código e versão, e
       **as colunas são exatamente as do `on conflict` da 0023**: um índice
       parcial é um alvo válido desde que as colunas coincidam, a cláusula `where`
       é que não é precisa do lado do `on conflict` quando a linha inserida
       satisfaz o predicado — e satisfaz, porque o seed insere com
       `clinica_id = null`.
     · **Índice parcial nas DA CLÍNICA** — `unique (clinica_id, codigo, versao)
       where clinica_id is not null`, para uma clínica não ter dois textos iguais.

   Dois índices, cada um a governar o seu caso, e nenhum deles a mexer no que já
   foi instalado. */
alter table public.consentimento_textos
  drop constraint if exists consentimento_textos_versao_unica;

/* Os índices das tentativas anteriores, se alguma tiver chegado a correr. */
drop index if exists public.uq_consentimento_textos_por_clinica;
drop index if exists public.uq_consentimento_textos_partilhados;

/* O MODELO PARTILHADO: uma versão por código. As colunas são as do `on conflict`
   da migração 0023, e é isso que faz o seed continuar a correr sem lhe tocar. */
create unique index if not exists uq_consentimento_textos_partilhados
  on public.consentimento_textos (codigo, versao)
  where clinica_id is null;

/* O TEXTO DE CADA CLÍNICA: um por (clínica, código, versão). */
create unique index if not exists uq_consentimento_textos_da_clinica
  on public.consentimento_textos (clinica_id, codigo, versao)
  where clinica_id is not null;

/* E o índice de leitura. A política vai filtrar por `clinica_id`, e sem índice
   cada leitura de um texto percorre a tabela. */
create index if not exists idx_consentimento_textos_clinica
  on public.consentimento_textos (clinica_id, codigo)
  where ativo;

-- ---------------------------------------------------------------------------
-- 3. A POLÍTICA DE LEITURA — O FIM DO `using (true)`
-- ---------------------------------------------------------------------------
-- Substitui-se. A regra passa a ser: o modelo partilhado, ou o da minha clínica.
--
-- Isto não quebra nada do que já existe: os textos semeados pela 0023 ficaram com
-- `clinica_id = null`, continuam a ser lidos por todos, e **as assinaturas que
-- apontam para eles continuam válidas** — que é o ponto. O que muda é que o texto
-- que uma clínica escrever para si deixa de estar à vista das outras.
drop policy if exists consentimento_textos_leitura on public.consentimento_textos;

create policy consentimento_textos_leitura on public.consentimento_textos
  for select to authenticated
  using (clinica_id is null or clinica_id = clinia.current_clinica_id());

-- ---------------------------------------------------------------------------
-- 4. A POLÍTICA DE ESCRITA — COM A CLÍNICA
-- ---------------------------------------------------------------------------
-- `clinia.e_admin()` diz «administrador ou gestão» e **não filtra por clínica**.
-- Sozinho, deixava um administrador da clínica A escrever um texto marcado como
-- da clínica B. A condição passa a incluir a clínica.
--
-- E o texto PARTILHADO não se escreve daqui: `clinica_id is null` é o modelo do
-- sistema, e um administrador de clínica não é o sistema. Isso fecha a
-- possibilidade de uma clínica reescrever o consentimento que todas as outras
-- usam — que seria a pior versão deste defeito. */
drop policy if exists consentimento_textos_escrita on public.consentimento_textos;

create policy consentimento_textos_escrita on public.consentimento_textos
  for insert to authenticated
  with check (
    clinia.e_admin()
    and clinica_id is not null
    and clinica_id = clinia.current_clinica_id()
  );

/* E o mesmo para alterar. Sem isto, uma clínica que não pode CRIAR o modelo
   partilhado podia ALTERÁ-LO — e o efeito seria o mesmo. */
drop policy if exists consentimento_textos_alteracao on public.consentimento_textos;

create policy consentimento_textos_alteracao on public.consentimento_textos
  for update to authenticated
  using (clinia.e_admin() and clinica_id = clinia.current_clinica_id())
  with check (clinia.e_admin() and clinica_id = clinia.current_clinica_id());

-- Mas há uma armadilha: uma política de UPDATE que não permita ver a linha
-- **não impede a alteração** de uma linha que já não se vê — impede é o
-- `using`. Aqui o `using` exige `clinica_id = current_clinica_id()`, e para as
-- partilhadas `clinica_id` é `null`, logo a comparação é `null` e a linha não é
-- visível para alteração. É o comportamento certo, e está explícito.

-- ---------------------------------------------------------------------------
-- 5. O GATILHO DE IMUTABILIDADE
   ---------------------------------------------------------------------------
-- A migração 0023 pôs um gatilho `t_consentimento_textos_imutaveis` para um texto
-- assinado não poder ser reescrito. Não se toca nele: continua a ser a proteção
-- mais importante desta tabela. Esta migração acrescenta o PERÍMETRO; o gatilho
-- garante a INTEGRIDADE.

-- ---------------------------------------------------------------------------
-- 6. OS PRIVILÉGIOS
   ---------------------------------------------------------------------------
-- Ficam como estavam (`select` e `insert` a `authenticated`, com `update` a ser
-- preciso para o ecrã de gestão). Quem decide é o RLS, e o RLS passa a decidir
-- por clínica.
grant select, insert, update on public.consentimento_textos to authenticated;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Depois desta migração, com um administrador da clínica A:
--
--   1. Vê os textos partilhados (os da 0023) e os da clínica A. Não vê os da B:
--
--        select codigo, versao, clinica_id from public.consentimento_textos;
--
--   2. Pode criar um texto para a clínica A:
--
--        insert into public.consentimento_textos
--          (clinica_id, codigo, versao, titulo, corpo, tipo)
--        values (clinia.current_clinica_id(), 'tratamento', 'v2', '...', '...', 'tratamento');
--
--   3. E NÃO pode criar um texto marcado como de outra clínica, nem reescrever
--      o modelo partilhado:
--
--        insert into public.consentimento_textos
--          (clinica_id, codigo, versao, titulo, corpo, tipo)
--        values ('<uuid-da-clinica-B>', 'x', 'v1', 'x', 'x', 'tratamento');
--        -- tem de recusar
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0029_rls_por_catalogo.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0029 — O RLS DEIXA DE DEPENDER DE UMA LISTA À MÃO
-- ============================================================================
--
-- O DEFEITO, E ELE NÃO É UM CASO — É UMA CLASSE
-- ============================================================================
--
-- Um auditor externo escreveu:
--
--   «Confirmar cobertura RLS em TODAS as tabelas. O RLS é ativado por loop sobre
--    arrays — é preciso garantir que nenhuma tabela (sobretudo faturação,
--    consentimentos, media, audit_log) ficou de fora do array, senão há fuga
--    entre clínicas.»
--
-- Ele não tinha o código à frente quando escreveu isto; escreveu-o como
-- desconfiança. **Fui ver, e ele tem razão.**
--
-- A migração 0010 liga o RLS assim (o delimitador está escrito por extenso de
-- propósito: um cifrão duplo dentro de um comentário faz o SQL Editor do
-- Supabase perder-se e reportar o erro na linha errada — há um teste que o
-- apanha, e apanhou este comentário quando o escrevi, e apanhou-o OUTRA VEZ na
-- frase que o explicava):
--
--     do <delimitador>
--     declare
--       t text;
--       tabelas text[] := array['clinicas','perfis',...];
--     begin
--       foreach t in array tabelas loop
--         execute format('alter table public.%I enable row level security;', t);
--       end loop;
--     end <delimitador>;
--
-- **A lista é fixa, e está escrita no ficheiro.** Por isso:
--
--   · cobre as tabelas que existiam em 0010 — migração 0010;
--   · cobre as que a 0013 acrescentou, porque alguém se lembrou de as inscrever
--     e o comentário no ficheiro até o diz: «uma tabela nova tem de ser inscrita
--     aqui para receber os grants»;
--   · e **NÃO cobre nenhuma das que vieram depois**: as da faturação (0017, 0018,
--     0020), as do consentimento (0023), as das alergias (0024)…
--
-- **Uma lista à mão não pode cobrir o que ainda não foi escrito.** Este defeito
-- não se corrige acrescentando nomes: corrige-se deixando de ter lista.
--
-- ============================================================================
-- PORQUE É QUE ISTO NÃO APARECEU ATÉ AGORA
-- ============================================================================
--
-- Duas razões, e nenhuma delas é boa:
--
--   1. **Os testes medem o que a lista faz, não o que ela esquece.** O
--      `testar_isolamento.mjs` verifica que as tabelas COM `clinica_id` têm RLS e
--      política — e as esquecidas têm `clinica_id`, logo a verificação passa por
--      elas sem as ver. A verificação pergunta às tabelas certas; o defeito está
--      nas outras.
--
--   2. **Nos ambientes que testei, o RLS acabou ligado por outra via.** A
--      auditoria da fronteira, contra a Elipse ao vivo, diz «nenhuma tabela
--      devolve dados sem sessão» — mas isso pode ser por RLS, por falta de
--      permissão, ou por a tabela estar vazia. **«Não vi fuga» não é o mesmo que
--      «a proteção está lá».**
--
-- ============================================================================
-- A CORREÇÃO
-- ============================================================================
--
-- Percorrer o CATÁLOGO em vez de uma lista. Uma tabela nova passa a receber RLS
-- no dia em que é criada, sem ninguém se lembrar de nada.
--
-- Três decisões que valem a pena explicar:
--
--   a) **Percorre `pg_class`, não `information_schema`.** O information_schema
--      esconde linhas a quem não é dono em alguns casos, e uma auditoria que não
--      vê uma tabela é uma auditoria que a aprova.
--
--   b) **Liga o RLS e não o desliga nunca.** Um `enable` é aditivo: não há forma
--      de isto abrir uma tabela que estivesse fechada. O contrário — um
--      `disable` — seria a migração mais perigosa deste repositório.
--
--   c) **Não cria políticas.** Uma tabela com RLS ligado e sem política **nega
--      tudo**, que é o lado seguro do erro. Se alguma tabela estava a depender de
--      não ter RLS para funcionar, ela vai parar de funcionar — e é bom que
--      pare, porque estava a funcionar sem proteção. Quem precisar de acesso
--      escreve a política que o justifica.
--
-- E fica um RELATÓRIO, não uma promessa: no fim a migração diz quantas tabelas
-- ligou, e falha se alguma ficar sem RLS depois disto. Uma migração que diz
-- «feito» sem contar o que fez não serve para uma auditoria.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. LIGAR O RLS EM TUDO O QUE É TABELA DE DADOS
-- ---------------------------------------------------------------------------
do $$
declare
  r        record;
  v_novo   integer := 0;
  v_ja     integer := 0;
begin
  for r in
    select c.relname as nome, c.relrowsecurity as ja_tem
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'          -- tabela normal; partições não se ligam assim
       and not c.relispartition
     order by c.relname
  loop
    if r.ja_tem then
      v_ja := v_ja + 1;
    else
      execute format('alter table public.%I enable row level security;', r.nome);
      v_novo := v_novo + 1;
      raise notice 'RLS ligado em public.% (nao estava)', r.nome;
    end if;
  end loop;

  raise notice 'RLS: % tabela(s) ja tinham, % passaram a ter.', v_ja, v_novo;

  /* E se alguma continuar sem RLS, isto falha. Não se trata de confiar no loop:
     trata-se de o verificar depois de correr. */
  select count(*) into v_novo
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not c.relispartition and not c.relrowsecurity;

  if v_novo > 0 then
    raise exception
      'Ficaram % tabela(s) em public sem RLS depois desta migracao. Nao pode ser.', v_novo;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. E OS GRANTS, PELA MESMA RAZÃO
-- ---------------------------------------------------------------------------
-- O mesmo array da 0010 também fazia os `grant`. Uma tabela criada depois de
-- 0010 sem `grant` explícito na sua própria migração funciona **por acidente** —
-- porque o Supabase concede por omissão nos seus papéis. É a mesma dependência
-- implícita do defeito 78 (a sequência sem permissão), e vale a pena fechá-la
-- pela mesma via: percorrer o catálogo.
--
-- `authenticated` recebe os quatro privilégios de tabela. **Isto não abre nada**:
-- quem decide o que cada clínica vê é o RLS, que acabou de ser ligado em tudo,
-- e as políticas já existem por tabela. O `grant` só decide se o pedido chega a
-- ser avaliado.
do $$
declare
  r record;
begin
  for r in
    select c.relname as nome
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated;', r.nome);
    execute format('grant all on public.%I to service_role;', r.nome);
  end loop;

  /* E uma exceção deliberada, que já vinha de trás: o registo de auditoria é
     append-only e NÃO se escreve à mão. `clinia.auditar()` é um gatilho
     `security definer` e corre como dono. O `grant` acima acaba de lho dar — por
     isso se tira aqui, logo a seguir, e num sítio onde se lê. */
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'audit_log' and c.relkind = 'r'
  ) then
    revoke insert, update, delete on public.audit_log from authenticated;
  end if;
end $$;

comment on table public.audit_log is
  'Registo de auditoria append-only (RGPD art. 30). A escrita direta esta FECHADA de proposito: `revoke insert, update, delete ... from authenticated` e sem grant na sequencia. O unico caminho legitimo e a funcao clinia.auditar(), que e um gatilho `security definer` e corre como dono. Nenhum utilizador, nem administrador, insere ou altera diretamente.';

-- ---------------------------------------------------------------------------
-- 3. O RELATÓRIO
-- ---------------------------------------------------------------------------
do $$
declare
  v_tabelas integer;
  v_sem_rls integer;
  v_sem_pol integer;
  v_lista   text;
begin
  select count(*) into v_tabelas
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition;

  select count(*) into v_sem_rls
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition
     and not c.relrowsecurity;

  /* Tabelas com RLS ligado mas SEM política nenhuma: negam tudo. Não é fuga — é
     uma tabela que ninguém consegue usar. Vale a pena listá-las, porque pode ser
     um ecrã que deixou de funcionar sem ninguém saber porquê. */
  select string_agg(c.relname, ', ' order by c.relname) into v_lista
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition
     and c.relrowsecurity
     and not exists (select 1 from pg_policy p where p.polrelid = c.oid);

  select count(*) into v_sem_pol
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition
     and c.relrowsecurity
     and not exists (select 1 from pg_policy p where p.polrelid = c.oid);

  raise notice '--- RLS ---';
  raise notice '  % tabela(s) de dados no schema public.', v_tabelas;
  raise notice '  % sem RLS ligado (tem de ser 0).', v_sem_rls;
  raise notice '  % com RLS mas sem politica nenhuma.', v_sem_pol;
  if v_lista is not null then
    raise notice '  Sem politica (negam tudo): %', v_lista;
  end if;
end $$;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Depois desta migração, o RELATÓRIO acima tem de dizer «0 sem RLS ligado».
--
-- E a verificação que prova o que interessa, contra duas clínicas a sério:
--
--   node tools/testar_duas_clinicas.mjs
--   node tools/testar_textos_consentimento.mjs
--
-- E a auditoria, contra a base de dados viva:
--
--   node tools/auditar_rls.mjs
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0030_modulo_respeita_o_produto.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0030 — Um módulo de reabilitação não se liga a uma
--                            clínica de endoscopia
--
-- PORQUÊ ESTA MIGRAÇÃO
-- ============================================================================
-- O gatilho `clinIA.ativar_mfr_em_clinica_nova` foi escrito quando só existia
-- UM produto. Ligava o módulo MFR a todas as clínicas criadas, sem olhar ao
-- produto — e a intenção era boa e mantém-se: **nenhuma clínica deve nascer sem
-- nenhum módulo ativo**, senão o administrador entra e não consegue fazer nada.
--
-- Mas quando o segundo produto apareceu (endoscopy), o gatilho ficou errado sem
-- ninguém lhe tocar. Uma clínica de endoscopia passava a nascer com:
--
--   · o módulo MFR ligado;
--   · a linha em `clinica_modulos` que o autoriza a registar atos de MFR;
--   · os ecrãs de reabilitação disponíveis — avaliação pelos três vetores
--     (Dor · Movimento · Função), sessões SOAP, plano com critério de alta.
--
-- Ou seja: as duas linhas de produto misturadas exatamente no sítio onde o
-- desenho as quer separadas. E o pior é que não dava erro nenhum — a clínica de
-- endoscopia simplesmente tinha, à espera, um conjunto de ecrãs clínicos que não
-- são dela.
--
-- O QUE ESTA MIGRAÇÃO FAZ
-- ============================================================================
--   1. Corrige o gatilho para ligar o primeiro módulo DISPONÍVEL **do produto
--      da clínica**. Rehab -> MFR. Endoscopy -> o primeiro módulo de endoscopia
--      disponível, quando houver algum; hoje não há nenhum, e por isso uma
--      clínica de endoscopia nasce sem módulos — o que é correto: não se liga o
--      que ainda não existe.
--   2. Tira o MFR das clínicas de endoscopia que já o tenham ligado por engano.
--      Isto inclui a clínica de ensaio, que foi criada com o gatilho antigo.
--
-- A segunda parte é a que faz a diferença entre corrigir o futuro e corrigir o
-- presente. Uma migração que só mexesse no gatilho deixaria a base atual com o
-- defeito lá dentro, e ninguém voltaria a olhar para ela.
--
-- O QUE **NÃO** FAZ
-- ============================================================================
-- Não apaga dados clínicos. Se uma clínica de endoscopia já tiver registos de
-- MFR, esta migração NÃO os apaga: desliga o módulo e deixa os registos onde
-- estão, porque apagar dados clínicos é uma decisão de quem é responsável por
-- eles, não de uma migração. Se houver registos, a migração avisa.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O GATILHO PASSA A RESPEITAR O PRODUTO
-- ---------------------------------------------------------------------------
create or replace function clinia.ativar_mfr_em_clinica_nova()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_modulo text;
begin
  select m.codigo into v_modulo
    from public.modulos m
   where m.produto = new.produto
     and m.disponivel
   order by m.ordem
   limit 1;

  if v_modulo is not null then
    insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo)
    values (new.id, v_modulo, true)
    on conflict (clinica_id, modulo_codigo) do nothing;
  end if;
  return new;
end $$;

comment on function clinia.ativar_mfr_em_clinica_nova() is
  'Ativa, numa clinica nova, o primeiro modulo DISPONIVEL do produto dessa clinica. Rehab -> MFR; endoscopy -> o primeiro modulo de endoscopia disponivel, quando existir. Garante que uma clinica nunca fica sem modulo ativo por esquecimento, sem nunca lhe ligar um modulo de outro produto.';


-- ---------------------------------------------------------------------------
-- 2. TIRAR O MFR DAS CLÍNICAS DE ENDOSCOPIA QUE O TENHAM LIGADO
--
-- A clínica fica com o módulo desligado, e não apagado: a linha passa a
-- `ativo = false` com a data. Assim vê-se no histórico que esteve ligado e
-- quando deixou de estar — uma linha apagada não conta essa história.
--
-- Os ecrãs de MFR desaparecem sozinhos, porque `clinia.modulo_ativo()` passa a
-- responder que não. É essa a vantagem de a separação ser imposta na base de
-- dados e não escondida na interface.
-- ---------------------------------------------------------------------------
do $$
declare
  v_afetadas int := 0;
  v_com_registos int := 0;
  v_clinica record;
begin
  for v_clinica in
    select c.id, c.nome
      from public.clinicas c
      join public.clinica_modulos cm on cm.clinica_id = c.id
     where c.produto = 'endoscopy'
       and cm.modulo_codigo = 'mfr'
       and cm.ativo
  loop
    /* Antes de desligar, verificar se há registos de MFR nesta clínica. Não os
       apagamos — mas quem administra tem de saber que eles existem, senão fica
       com dados órfãos e sem forma de lá chegar. */
    if exists (
      select 1 from public.atos_clinicos a
       where a.clinica_id = v_clinica.id and a.especialidade = 'mfr'
    ) then
      v_com_registos := v_com_registos + 1;
      raise warning 'A clinica "%" tem registos de MFR e vai ficar com o modulo desligado. Os registos NAO sao apagados: continuam legiveis, mas deixam de estar acessiveis pela interface. Decida o que fazer com eles.', v_clinica.nome;
    end if;

    update public.clinica_modulos
       set ativo = false,
           desativado_em = now()
     where clinica_id = v_clinica.id
       and modulo_codigo = 'mfr'
       and ativo;

    v_afetadas := v_afetadas + 1;
  end loop;

  if v_afetadas = 0 then
    raise notice 'Modulos MFR em clinicas de endoscopia: nenhum para corrigir.';
  else
    raise notice 'Modulos MFR desligados em clinicas de endoscopia: % (com registos de MFR: %).', v_afetadas, v_com_registos;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. VERIFICAÇÃO — a migração não confia em si própria
--
-- O projeto já apanhou defeitos reais com verificações dentro da migração. Esta
-- confirma as duas coisas que interessam: que o gatilho passou a respeitar o
-- produto, e que não ficou nenhuma clínica de endoscopia com MFR ativo.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_restantes int;
  v_mfr_disp boolean;
begin
  /* 3a. O gatilho referencia o produto da clínica? Se não, a substituição da
     função não chegou a acontecer — e o defeito continuaria a nascer em cada
     clínica nova, sem dar erro. */
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'clinia'
     and p.proname = 'ativar_mfr_em_clinica_nova';

  if v_def is null then
    raise exception 'A funcao clinia.ativar_mfr_em_clinica_nova nao existe depois da migracao.';
  end if;

  if position('new.produto' in v_def) = 0 then
    raise exception 'O gatilho continua a NAO olhar ao produto da clinica: uma clinica de endoscopia voltaria a nascer com o MFR ligado.';
  end if;

  /* 3b. Sobrou alguma clínica de endoscopia com MFR ativo? */
  select count(*) into v_restantes
    from public.clinicas c
    join public.clinica_modulos cm on cm.clinica_id = c.id
   where c.produto = 'endoscopy'
     and cm.modulo_codigo = 'mfr'
     and cm.ativo;

  if v_restantes > 0 then
    raise exception 'Ficaram % clinicas de endoscopia com o modulo MFR ativo.', v_restantes;
  end if;

  /* 3c. E o MFR continua disponível para o rehab? A correção não pode ter
     partido o produto que já funcionava. */
  select disponivel into v_mfr_disp
    from public.modulos
   where codigo = 'mfr';

  if v_mfr_disp is not true then
    raise exception 'O modulo MFR deixou de estar disponivel: a correcao partiu o produto rehab.';
  end if;

  raise notice 'Modulos por produto: um modulo de reabilitacao deixou de se ligar a clinicas de endoscopia.';
end $$;


-- ----------------------------------------------------------------------------
-- 0031_contexto_expoe_o_produto.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0031 — O contexto do utilizador passa a dizer o PRODUTO
--
-- PORQUÊ ESTA MIGRAÇÃO
-- ============================================================================
-- O programa serve duas linhas de produto: `rehab` (MFR e afins) e `endoscopy`
-- (gastro, ORL, pneumo, uro, gineco). A base de dados distingue-as desde a
-- migração 0013b — `clinicas.produto`, a tabela `modulos` e a `clinica_modulos`.
--
-- O CLIENTE é que não sabia qual estava a servir, e por isso uma clínica de
-- endoscopia abria com o vocabulário do rehab: «Avaliação», «Planos», «Sessões»,
-- «Evolução», e um seletor de especialidades que oferecia «Fisioterapeuta». Não
-- dava erro nenhum — e é esse o problema. Um menu errado que funciona é pior do
-- que um menu que falha, porque ninguém o vai corrigir.
--
-- Esta migração acrescenta `produto` ao contexto que a aplicação já pede UMA vez
-- no arranque. Não há consulta nova: a vista JÁ fazia `left join public.clinicas
-- c`, e o produto estava a um `c.produto` de distância.
--
-- PORQUE NÃO SE ACRESCENTOU À MIGRAÇÃO 0017
-- ============================================================================
-- A 0017 é o registo do que foi feito nesse dia, e continua a ser a definição
-- vigente da vista até esta migração. O projeto já resolveu isto assim antes — a
-- 0012 e a 0017 redefinem vistas de migrações anteriores em vez de as editar — e
-- a razão é concreta: uma migração que fica a ser editada deixa de dizer o que
-- aconteceu. Quem ler a 0017 daqui a um ano tem de ver o que ela fez, e não o que
-- ela faz hoje.
--
-- O QUE ESTA MIGRAÇÃO **NÃO** FAZ
-- ============================================================================
-- Não restringe nada. O tipo `especialidade` continua com os oito valores, e o
-- `produto` é informativo. Quem decide o que se OFERECE é a interface, e quem
-- decide o que se ACEITA continua a ser a base de dados — a mesma separação que
-- já estava certa na 0013b.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. A VISTA, COM O PRODUTO
--
-- `security_invoker = true` mantém-se: sem isso a vista corre com os privilégios
-- de quem a criou e contorna o RLS. Está explicado na migração 0012.
-- ---------------------------------------------------------------------------
/* O `produto` VAI NO FIM, E NÃO É ONDE ELE FICA MELHOR — É ONDE ELE FUNCIONA.
 *
 * `create or replace view` só pode ACRESCENTAR colunas ao fim. Não pode
 * renomear, reordenar, nem inserir no meio.
 *
 * A primeira versão desta migração punha `c.produto` ANTES de `p.utente_id` —
 * que é onde ele se lê melhor. Para o PostgreSQL isso é «a coluna `utente_id`
 * passou a chamar-se `produto`», e ele recusa:
 *
 *     cannot change name of view column "utente_id" to "produto"
 *
 * **O erro só apareceu ao fundir os dois ramos do produto**, porque até aí cada
 * ramo corria sozinho. É o tipo de defeito que uma fusão revela e um ramo não.
 *
 * TENTEI LARGAR A VISTA E RECRIAR, E ISSO PARTIU OUTRA COISA. O `drop` leva os
 * PRIVILÉGIOS atrás, e esta vista não tem `grant` explícito em lado nenhum —
 * depende dos privilégios por omissão. Resultado: o teste do schema passou a
 * falhar com `aclcheck_error` a ler a vista.
 *
 * E a migração 0017 já tinha escrito a resposta, num comentário que eu não li:
 *
 *     «Acrescentar no fim é o que permite substituir a vista em vez de a largar
 *      e recriar, e sem partir, durante um instante, tudo o que a lê no arranque.»
 *
 * **Largar uma vista que o programa lê no arranque deixa-o sem contexto durante
 * um instante** — e num sistema clínico isso é uma janela em que os ecrãs não
 * sabem quem está a usá-los.
 *
 * Portanto: `produto` no fim, e a convenção da 0017 mantém-se. A ordem das
 * colunas de uma vista é uma decisão que se paga; esta paga-se com uma linha
 * menos legível e uma migração que corre em qualquer instalação. */
create or replace view public.vw_meu_contexto
with (security_invoker = true) as
select p.id                as perfil_id,
       p.nome,
       p.email,
       p.perfil,
       p.especialidade,
       p.clinica_id,
       c.nome              as clinica_nome,
       c.especialidades,
       p.utente_id,
       clinia.e_clinico()  as e_clinico,
       clinia.e_admin()    as e_admin,
       p.preferencias,
       clinia.e_gestor()   as e_gestor,
       /* O produto da clínica. É o que diz ao programa qual das duas linhas de
          produto está a servir, e por isso que vocabulário mostrar.
          NO FIM, e por isso mesmo — ver o comentário acima. */
       c.produto
  from public.perfis p
  left join public.clinicas c on c.id = p.clinica_id
 where p.id = auth.uid();

comment on view public.vw_meu_contexto is
  'Contexto do utilizador autenticado no arranque. Expoe e_admin (so administrador), e_gestor (administrador ou gestao) e o produto da clinica (rehab ou endoscopy).';


-- ---------------------------------------------------------------------------
-- 2. VERIFICAÇÃO — a migração não confia em si própria
--
-- O defeito que esta migração corrige não deu erro nenhum durante meses. Uma
-- verificação que só confirma «correu» não serve de nada; esta confirma as
-- propriedades de que a interface depende.
-- ---------------------------------------------------------------------------
do $$
declare
  v_produto_existe boolean;
  v_invoker boolean;
  v_clinicas_sem_produto int;
begin
  /* 2a. A coluna existe na vista? Se não, a aplicação continua a não saber que
     produto serve — e o menu de rehab volta a aparecer numa clínica de
     endoscopia, em silêncio. */
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'vw_meu_contexto'
       and column_name = 'produto'
  ) into v_produto_existe;

  if not v_produto_existe then
    raise exception 'A vista vw_meu_contexto continua sem a coluna produto: o cliente nao consegue saber que produto serve.';
  end if;

  /* 2b. `security_invoker` continua ligado? Sem ele a vista contorna o RLS, e
     passaria a mostrar contexto de outros utilizadores. É uma regressão de
     SEGURANÇA, e é a razão pela qual este `create or replace` tem de repetir a
     cláusula em vez de a herdar — o PostgreSQL não a preserva. */
  select coalesce(
    (select option_value = 'true'
       from pg_options_to_table(c.reloptions)
      where option_name = 'security_invoker'),
    false
  ) into v_invoker
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'vw_meu_contexto';

  if not v_invoker then
    raise exception 'A vista vw_meu_contexto perdeu security_invoker: passaria a contornar o RLS.';
  end if;

  /* 2c. Alguma clínica sem produto? A coluna tem `not null default 'rehab'`, por
     isso não deve haver nenhuma — mas uma clínica sem produto faria o cliente
     cair na omissão, e é melhor saber disso do que adivinhar. */
  select count(*) into v_clinicas_sem_produto from public.clinicas where produto is null;
  if v_clinicas_sem_produto > 0 then
    raise warning 'Ha % clinicas sem produto definido. O cliente assume rehab.', v_clinicas_sem_produto;
  end if;

  raise notice 'Contexto do utilizador: passa a expor o produto da clinica.';
end $$;


-- ----------------------------------------------------------------------------
-- 0032_dicionario_endoscopia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0032 — DICIONÁRIO DE ENDOSCOPIA
--
-- Este ficheiro é o dicionário do módulo de endoscopia. O núcleo não sabe o que
-- é a escala de Boston nem a classificação de Paris; sabe o que é um ato
-- clínico. Tudo o que é vocabulário de endoscopia vive aqui.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O QUE ESTE DICIONÁRIO GUARDA, E PORQUE É TIPADO E NÃO jsonb
-- ─────────────────────────────────────────────────────────────────────────────
-- A tentação era guardar o `gastro.json` numa coluna `jsonb` e ler o que fosse
-- preciso. Não se fez, pela mesma razão que já está escrita na migração 0007
-- para o MFR: **o que precisa de ser agregado, comparado e contado tem de ser
-- tipado**. O ADR é uma contagem de lesões sobre exames; o tempo de retirada é
-- uma subtração entre dois instantes; a preparação adequada é um limiar sobre um
-- total. Nada disso se calcula com rigor a partir de texto dentro de um jsonb.
--
-- O jsonb continua a existir, e é onde deve estar: nos DADOS do exame que são
-- narrativos e esparsos. Não no vocabulário.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- A REGRA CENTRAL DESTE MÓDULO, IMPOSTA PELO SCHEMA
-- ─────────────────────────────────────────────────────────────────────────────
--     Uma classificação CATEGÓRICA nunca produz um número.
--
-- Paris é `0-IIa`. Se lhe derem uma escala, sai um número que vai para um
-- relatório com aparência de válido — e ninguém o vai questionar, porque um
-- número é mais persuasivo do que uma categoria.
--
-- Esta regra NÃO fica em comentário nem em disciplina de quem programa: fica em
-- DUAS TABELAS SEPARADAS. `endo_classificacao_valores` guarda categorias e só
-- tem `codigo`; `endo_classificacao_escala` guarda escalas numéricas e só tem
-- `valor`. Não há coluna onde caiba a coisa errada, e por isso não há como a
-- escrever. É a diferença entre uma regra e uma convenção.
--
-- Quem decidir um dia que «é mais simples ter uma tabela só» está a desfazer
-- isto — e o teste `testar-dicionario-endoscopia.mjs` existe para o apanhar.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- AS QUATRO REGRAS DO DICIONÁRIO, E ONDE CADA UMA FICA
-- ─────────────────────────────────────────────────────────────────────────────
--   1. «Um código nunca se reutiliza com outro significado.»  -> a chave é o
--      código, e há `estado` para o marcar como obsoleto sem o apagar.
--   2. «Nenhum código se apaga.»  -> `estado` + `obsoleto_em` + `obsoleto_motivo`.
--      Um relatório assinado tem de continuar a ser interpretável para sempre.
--   3. «As categóricas não passam pelo motor de escalas.»  -> as duas tabelas
--      separadas, descritas acima.
--   4. «Todo o valor traz a versão da norma.»  -> `versao` é NOT NULL nas
--      classificações e nos seus valores. Sem versão, dois exames do mesmo
--      doente não são comparáveis — e é isso que a versão garante.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. OS PROCEDIMENTOS
--
-- EDA, colonoscopia, CPRE. O que se faz, não o que se encontra.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_procedimentos (
  codigo        text primary key,
  nome          text not null,
  modulo        text not null default 'gastro' references public.modulos(codigo) on delete restrict,
  ordem         smallint not null default 100,

  /* O que é OBRIGATÓRIO registar neste procedimento. É uma lista de chaves de
     campos, e fica em jsonb de propósito: é uma lista de configuração, não um
     dado que se agregue. O que se agrega — «quantos exames ficaram sem tempo de
     retirada» — calcula-se a partir dos dados do exame, não daqui. */
  obrigatorios  jsonb not null default '[]'::jsonb,

  /* Porque é que estes campos são obrigatórios. Um requisito sem razão escrita
     é o primeiro a ser contornado. */
  nota_obrigatorios text,

  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.endo_procedimentos is
  'Procedimentos de endoscopia. O `obrigatorios` diz o que nao pode faltar em cada um - e e o que permite calcular indicadores de qualidade sem campos em branco.';


-- ---------------------------------------------------------------------------
-- 2. AS LOCALIZAÇÕES
--
-- 30 no dicionário. São partilhadas entre procedimentos: a mesma localização
-- pode ser visitada numa EDA e numa colonoscopia, e não faz sentido ter duas.
-- O que diz se é relevante para um procedimento é a tabela de ligação (secção 5).
-- ---------------------------------------------------------------------------
create table if not exists public.endo_localizacoes (
  codigo        text primary key,
  rotulo        text not null,
  /* Nota clínica da localização — por exemplo «2 cm acima da linha anal» no
     reto baixo. É o que evita que dois endoscopistas a marquem em sítios
     diferentes. */
  nota          text,
  ordem         smallint not null default 100,
  estado        text not null default 'ativo',
  obsoleto_em   timestamptz,
  obsoleto_motivo text,
  created_at    timestamptz not null default now()
);

comment on table public.endo_localizacoes is
  'Vocabulario anatomico da endoscopia. Partilhado entre procedimentos; a ligacao a cada procedimento esta em endo_procedimento_localizacoes.';

create index if not exists idx_endo_localizacoes_ordem on public.endo_localizacoes (ordem);


-- ---------------------------------------------------------------------------
-- 3. OS ACHADOS E AS INTERVENÇÕES
--
-- Duas tabelas e não uma com um `tipo`, porque são coisas diferentes: um achado
-- é o que se VIU, uma intervenção é o que se FEZ. Misturá-las num só catálogo
-- faria com que um relatório pudesse dizer «polipectomia» onde devia dizer
-- «pólipo» — e a contagem de lesões, que é o ADR, sairia errada.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_achados (
  codigo        text primary key,
  rotulo        text not null,
  /* Agrupamento clínico: «normal», «mucosa», «lesao», «hemorragia»… Serve para
     ordenar o seletor de forma útil e para separar o que conta como lesão. */
  grupo         text,
  ordem         smallint not null default 100,
  estado        text not null default 'ativo',
  obsoleto_em   timestamptz,
  obsoleto_motivo text,
  created_at    timestamptz not null default now()
);

comment on table public.endo_achados is
  'O que se VE na endoscopia. Separado das intervencoes de proposito: contar lesoes (o ADR) exige que um achado nao se confunda com o que se fez a ele.';

create table if not exists public.endo_intervencoes (
  codigo        text primary key,
  rotulo        text not null,
  grupo         text,
  ordem         smallint not null default 100,
  estado        text not null default 'ativo',
  obsoleto_em   timestamptz,
  obsoleto_motivo text,
  created_at    timestamptz not null default now()
);

comment on table public.endo_intervencoes is
  'O que se FEZ no exame: polipectomia, esfincterotomia, biopsias.';


-- ---------------------------------------------------------------------------
-- 4. AS CLASSIFICAÇÕES — E A REGRA CENTRAL
--
-- O cabeçalho diz o que é a classificação e de que TIPO é. O tipo é que decide
-- em qual das duas tabelas seguintes os valores podem viver.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_classificacoes (
  codigo        text primary key,
  nome          text not null,
  tipo          text not null check (tipo in ('categorico', 'numerico')),
  dominio       text not null,
  /* A VERSÃO DA NORMA. Obrigatória, e é a regra 4 do dicionário: sem versão,
     dois exames do mesmo doente feitos em anos diferentes não são comparáveis, e
     ninguém sabe se a diferença é do doente ou da norma que mudou. */
  versao        text not null,

  /* Por onde a escala se aplica, quando é numérica: `segmento` na Boston (três
     pontuações, uma por segmento), `global` nas restantes. Nas categóricas fica
     a `null` — não há escala. */
  escala_por    text check (escala_por in ('segmento', 'global')),

  /* O total, quando a escala tem um. A Boston tem máximo 9 (três segmentos × 3).
     Fica aqui, e não calculado, porque é a DEFINICAÇÃO da norma e não um
     resultado: o que se calcula a partir dos exames é outra coisa. */
  total_min     smallint,
  total_max     smallint,

  /* ESTADO DE REVISÃO CLÍNICA. No dicionário atual, 7 das 12 classificações
     estão por confirmar contra a norma. Isto NÃO é decoração: é o que impede que
     um valor por confirmar entre em produção sem ninguém dar por isso — e é a
     razão pela qual o `validar-dicionario.mjs` avisa em vez de aprovar. */
  conferir      boolean not null default false,
  nota          text,

  estado        text not null default 'ativo',
  obsoleto_em   timestamptz,
  obsoleto_motivo text,
  created_at    timestamptz not null default now()
);

comment on table public.endo_classificacoes is
  'Cabecalho das classificacoes. O `tipo` decide onde os valores podem viver: categorico so em endo_classificacao_valores, numerico so em endo_classificacao_escala.';

comment on column public.endo_classificacoes.conferir is
  'Valor por confirmar contra a norma citada em `versao`. Nao entra em producao sem revisao clinica.';

create index if not exists idx_endo_classificacoes_tipo on public.endo_classificacoes (tipo);
create index if not exists idx_endo_classificacoes_conferir on public.endo_classificacoes (conferir) where conferir;


/* ---------------------------------------------------------------------------
   4a. OS VALORES CATEGÓRICOS
   ---------------------------------------------------------------------------
   Só tem `codigo` e `rotulo`. NÃO TEM COLUNA NUMÉRICA, e é isso que faz a regra.
   Paris vive aqui: `0-IIa`, `0-IIb`, `0-III`, `misto`.
   --------------------------------------------------------------------------- */
create table if not exists public.endo_classificacao_valores (
  id            uuid primary key default gen_random_uuid(),
  classificacao text not null references public.endo_classificacoes(codigo) on delete restrict,
  codigo        text not null,
  rotulo        text not null,
  nota          text,
  ordem         smallint not null default 100,
  estado        text not null default 'ativo',
  obsoleto_em   timestamptz,
  obsoleto_motivo text,
  created_at    timestamptz not null default now(),
  unique (classificacao, codigo)
);

comment on table public.endo_classificacao_valores is
  'Valores CATEGORICOS. Nao existe coluna numerica nesta tabela, de proposito: um codigo categorico nunca produz um numero. Ver a nota no topo da migracao.';


/* ---------------------------------------------------------------------------
   4b. AS ESCALAS NUMÉRICAS
   ---------------------------------------------------------------------------
   Só tem `valor` e `rotulo`. Boston vive aqui: 0 a 3, com o significado de cada
   grau. Não tem coluna de código de categoria, pela mesma razão simétrica.
   --------------------------------------------------------------------------- */
create table if not exists public.endo_classificacao_escala (
  id            uuid primary key default gen_random_uuid(),
  classificacao text not null references public.endo_classificacoes(codigo) on delete restrict,
  valor         smallint not null,
  rotulo        text not null,
  nota          text,
  created_at    timestamptz not null default now(),
  unique (classificacao, valor)
);

comment on table public.endo_classificacao_escala is
  'Valores NUMERICOS de uma escala. Nao existe coluna de codigo nesta tabela, de proposito.';


-- ---------------------------------------------------------------------------
-- 5. AS LIGAÇÕES: QUE VOCABULÁRIO SERVE QUE PROCEDIMENTO
--
-- Sem isto, o seletor de uma EDA mostraria as localizações da colonoscopia, e
-- quem regista perderia tempo a procurar o que não existe. O dicionário diz
-- quais são relevantes em cada procedimento.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_procedimento_localizacoes (
  procedimento  text not null references public.endo_procedimentos(codigo) on delete cascade,
  localizacao   text not null references public.endo_localizacoes(codigo) on delete restrict,
  /* Marco a fotografar: a evidência de que o exame chegou onde diz que chegou.
     É o que permite auditar a intubação cecal sem confiar na palavra de quem
     escreveu o relatório. */
  marco         boolean not null default false,
  ordem         smallint not null default 100,
  primary key (procedimento, localizacao)
);

comment on table public.endo_procedimento_localizacoes is
  'Que localizacoes cada procedimento usa, e quais sao marco a fotografar. Os marcos sao a prova de que o exame chegou onde o relatorio diz.';

create table if not exists public.endo_procedimento_achados (
  procedimento  text not null references public.endo_procedimentos(codigo) on delete cascade,
  achado        text not null references public.endo_achados(codigo) on delete restrict,
  ordem         smallint not null default 100,
  primary key (procedimento, achado)
);

create table if not exists public.endo_procedimento_intervencoes (
  procedimento  text not null references public.endo_procedimentos(codigo) on delete cascade,
  intervencao   text not null references public.endo_intervencoes(codigo) on delete restrict,
  ordem         smallint not null default 100,
  primary key (procedimento, intervencao)
);

create table if not exists public.endo_procedimento_classificacoes (
  procedimento  text not null references public.endo_procedimentos(codigo) on delete cascade,
  classificacao text not null references public.endo_classificacoes(codigo) on delete restrict,
  ordem         smallint not null default 100,
  primary key (procedimento, classificacao)
);

comment on table public.endo_procedimento_classificacoes is
  'Que classificacoes se aplicam a cada procedimento. Uma EDA nao usa a escala de Boston - e sem isto o seletor mostraria o que nao se aplica.';


-- ---------------------------------------------------------------------------
-- 6. AS SEGMENTOS DA PREPARAÇÃO (a Boston pontua por segmento)
--
-- A escala de Boston dá uma pontuação POR SEGMENTO, e o total é a soma. Sem uma
-- lista fixa de segmentos, «preparação adequada (>= 6)» não é verificável: não
-- se sabe se o total devia ter três parcelas ou cinco.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_segmentos (
  codigo        text primary key,
  rotulo        text not null,
  ordem         smallint not null default 100,
  created_at    timestamptz not null default now()
);

comment on table public.endo_segmentos is
  'Segmentos usados pelas escalas que pontuam por segmento. A Boston soma tres: direito, transverso e esquerdo.';

create table if not exists public.endo_procedimento_segmentos (
  procedimento  text not null references public.endo_procedimentos(codigo) on delete cascade,
  segmento      text not null references public.endo_segmentos(codigo) on delete restrict,
  ordem         smallint not null default 100,
  primary key (procedimento, segmento)
);


-- ---------------------------------------------------------------------------
-- 7. updated_at
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  tabelas text[] := array['endo_procedimentos'];
begin
  foreach t in array tabelas loop
    execute format('drop trigger if exists t_%1$s_updated_at on public.%1$I;', t);
    execute format(
      'create trigger t_%1$s_updated_at before update on public.%1$I
         for each row execute function clinia.set_updated_at();', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 8. RLS E PRIVILÉGIOS
--
-- O DICIONÁRIO É GLOBAL E SÓ DE LEITURA, e é uma decisão:
--   · global, porque é vocabulário normativo — a classificação de Paris não é
--     diferente de clínica para clínica, e duplicá-la por tenant tornaria dois
--     relatórios de serviços diferentes incomparáveis, que é o oposto do que um
--     dicionário serve para fazer;
--   · só de leitura para `authenticated`, porque quem o altera é a migração e a
--     ferramenta que o gera a partir do `gastro.json` — não um utilizador a meio
--     de um exame. Um código acrescentado à mão no meio de um turno é um código
--     sem revisão clínica, e a regra 1 do dicionário diz que um código nunca se
--     reutiliza com outro significado. Escrever exige `service_role`.
--
-- A lista é construída a partir do catálogo, e não escrita à mão: uma tabela
-- `endo_*` nova passa a receber RLS sozinha. A lista fixa do 0010 já obrigou a
-- acrescentar tabelas à mão uma vez, e é o tipo de coisa que se esquece.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  for t in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and c.relname like 'endo\_%'
  loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('grant select on public.%I to authenticated;', t);
    execute format('grant all on public.%I to service_role;', t);
    execute format('drop policy if exists %1$s_leitura on public.%1$I;', t);
    execute format(
      'create policy %1$s_leitura on public.%1$I for select to authenticated using (true);', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 9. VERIFICAÇÃO — a migração não confia em si própria
--
-- O que se verifica aqui não é «correu». É a PROPRIEDADE de que este módulo
-- depende: que não existe maneira de escrever um número numa classificação
-- categórica. Se um dia alguém juntar as duas tabelas numa só, é isto que falha.
-- ---------------------------------------------------------------------------
do $$
declare
  v_categorica_com_numero int := 0;
  v_numerica_com_codigo int := 0;
  v_pgcrypto int;
  v_sem_rls text;
begin
  /* 9a. As tabelas existem e têm a forma que impõe a regra? */
  select count(*) into v_categorica_com_numero
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'endo_classificacao_valores'
     and column_name in ('valor', 'pontuacao', 'score', 'total');

  if v_categorica_com_numero > 0 then
    raise exception 'A tabela dos valores CATEGORICOS ganhou uma coluna numerica. Um codigo categorico nunca pode produzir um numero - ver a nota no topo desta migracao.';
  end if;

  select count(*) into v_numerica_com_codigo
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'endo_classificacao_escala'
     and column_name in ('codigo', 'rotulo_codigo');

  if v_numerica_com_codigo > 0 then
    raise exception 'A tabela das escalas NUMERICAS ganhou uma coluna de codigo de categoria.';
  end if;

  /* 9b. Ficou alguma tabela endo_* sem RLS? Uma tabela de dados clinicos sem RLS
     é uma fuga, e não um estilo. */
  select string_agg(c.relname, ', ') into v_sem_rls
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relname like 'endo\_%'
     and not c.relrowsecurity;

  if v_sem_rls is not null then
    raise exception 'Tabelas endo_* sem RLS ativo: %', v_sem_rls;
  end if;

  raise notice 'Dicionario de endoscopia criado. A regra categorico-nunca-numero fica imposta pelo schema, e nao por disciplina.';
end $$;


-- ----------------------------------------------------------------------------
-- 0033_exame_de_endoscopia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0033 — O EXAME DE ENDOSCOPIA
--
-- O dicionário existe (0032 + seed 0008). Este ficheiro é onde se guarda o
-- exame: o que foi feito, o que se viu, o que se classificou e o que se colheu.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O EXAME PENDURA-SE NUM ATO CLÍNICO
-- ─────────────────────────────────────────────────────────────────────────────
-- Não se inventa um segundo caminho para o mesmo conceito. O ato já traz quem,
-- quando, que utente, que episódio, o profissional e a assinatura — e é a
-- assinatura que torna um relatório imutável. O que é de endoscopia vive aqui.
--
-- É a mesma decisão da migração 0007, e a razão é a mesma: **o módulo não é
-- apenas jsonb.** O que precisa de ser agregado, comparado e contado tem de ser
-- tipado. O ADR é uma contagem de lesões sobre exames; o tempo de retirada é uma
-- subtração; a preparação adequada é um limiar sobre um total. Nada disso se
-- calcula com rigor a partir de texto dentro de um jsonb.
--
-- O jsonb continua a existir, e é onde deve estar: no que é narrativo e esparso.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O PONTO MAIS IMPORTANTE DESTA MIGRAÇÃO
-- ─────────────────────────────────────────────────────────────────────────────
-- A regra «uma classificação categórica nunca produz um número» já está imposta
-- no DICIONÁRIO, por duas tabelas separadas (0032). Isso não chega.
--
-- O dicionário diz o que é válido; é AQUI que os dados entram. Sem uma restrição
-- nesta tabela, o ecrã podia gravar um código categórico E um número na mesma
-- linha, e a separação do dicionário passava a ser decorativa — uma boa decisão
-- de desenho que ninguém verifica deixa de ser uma decisão.
--
-- A restrição `endo_lesao_classificacao_coerente` obriga a que:
--   · classificação CATEGÓRICA  -> valor_codigo preenchido, valor_numero NULO
--   · classificação NUMÉRICA    -> valor_numero preenchido, valor_codigo NULO
--
-- E é verificada contra o TIPO, que vive na tabela das classificações. Não basta
-- dizer «um dos dois»: é preciso dizer QUAL, senão um número continua a poder
-- entrar numa categórica.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE SE GUARDAM OS INSTANTES **E** OS TEMPOS
-- ─────────────────────────────────────────────────────────────────────────────
-- `inicio`/`fim` são o registo do que aconteceu. `tempo_insercao_min` e
-- `tempo_retirada_min` são o que o endoscopista mediu e escreveu.
--
-- Se só houvesse instantes, um cronómetro arrancado tarde dava um tempo errado e
-- não havia como o corrigir. Se só houvesse tempos, deixava de haver prova de
-- quando o exame aconteceu — e o tempo de retirada é um indicador auditável, não
-- uma declaração.
--
-- **Guarda-se o que foi medido e o que foi declarado. Quando divergem, é isso
-- que interessa saber.**
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O EXAME
-- ---------------------------------------------------------------------------
create table if not exists public.endo_exames (
  id                uuid primary key default gen_random_uuid(),
  clinica_id        uuid not null references public.clinicas(id) on delete restrict,
  ato_id            uuid not null references public.atos_clinicos(id) on delete cascade,
  utente_id         uuid not null references public.utentes(id) on delete restrict,

  procedimento      text not null references public.endo_procedimentos(codigo) on delete restrict,

  /* Os instantes. `fim` é opcional porque um exame a decorrer não tem fim — e
     um `fim` inventado para satisfazer um NOT NULL seria pior do que nenhum. */
  inicio            timestamptz not null default now(),
  fim               timestamptz,

  /* Os tempos DECLARADOS, em minutos. Ver a nota no topo. */
  tempo_insercao_min   smallint check (tempo_insercao_min is null or tempo_insercao_min >= 0),
  tempo_retirada_min   smallint check (tempo_retirada_min is null or tempo_retirada_min >= 0),

  /* Indicadores que o dicionário exige em TODA a colonoscopia. A preparação
     adequada (BBPS >= 6) calcula-se a partir dos segmentos, e o limiar fica no
     dicionário — não se guarda um booleano derivado, que ficaria errado no dia em
     que a norma mudasse. */
  intubacao_cecal   boolean,

  /* Campos que o dicionário marca como obrigatórios. Ficam em colunas próprias e
     não em jsonb porque entram em contagens: quantos exames ficaram sem
     indicação registada é uma pergunta de qualidade. */
  indicacao         text,
  sedacao           text,
  canulacao         text,
  fluoroscopia      boolean,
  preparacao_jejum  boolean,
  polipectomia_adequada boolean,
  recomendacao_seguimento text,
  ate_onde_se_chegou text,

  /* Complicações: array de códigos. É uma lista curta e esparsa — não se agrega
     por código, conta-se se houve ou não. */
  complicacoes      jsonb not null default '[]'::jsonb,

  /* O narrativo: observações, descrição, texto livre. É aqui que o jsonb serve. */
  dados             jsonb not null default '{}'::jsonb,

  estado            text not null default 'em_curso'
                    check (estado in ('em_curso', 'concluido', 'assinado')),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.perfis(id) on delete set null,

  /* UM EXAME POR ATO, como no MFR. Dois exames no mesmo ato seriam dois
     relatórios assinados para o mesmo procedimento. */
  constraint endo_exames_um_por_ato unique (ato_id),

  /* O fim não pode ser antes do início. Parece óbvio e é o tipo de erro que uma
     gravação apressada produz — e que daria um tempo de retirada negativo. */
  constraint endo_exames_fim_depois_do_inicio check (fim is null or fim >= inicio)
);

comment on table public.endo_exames is
  'O exame de endoscopia, pendurado num ato clinico. Guarda os instantes (o que aconteceu) e os tempos declarados (o que foi medido) - quando divergem, e isso que interessa.';

comment on column public.endo_exames.tempo_retirada_min is
  'Tempo de retirada DECLARADO. O indicador de qualidade audita-se comparando-o com (fim - inicio).';

create index if not exists idx_endo_exames_ato      on public.endo_exames (ato_id);
create index if not exists idx_endo_exames_utente   on public.endo_exames (utente_id);
create index if not exists idx_endo_exames_inicio   on public.endo_exames (inicio desc);
create index if not exists idx_endo_exames_estado   on public.endo_exames (estado);
create index if not exists idx_endo_exames_proc     on public.endo_exames (procedimento);


-- ---------------------------------------------------------------------------
-- 2. OS SEGMENTOS VISITADOS E O ASPETO DE CADA UM
--
-- Uma linha por localização do procedimento. `visitada` distingue «não cheguei
-- lá» de «não registei» — e sem essa distinção não há como auditar o alcance.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_exame_localizacoes (
  id                uuid primary key default gen_random_uuid(),
  exame_id          uuid not null references public.endo_exames(id) on delete cascade,
  localizacao       text not null references public.endo_localizacoes(codigo) on delete restrict,

  visitada          boolean not null default false,
  /* O aspeto NESTA localização. Um só, porque a mucosa de um segmento tem um
     aspeto; o que é focal (pólipo, úlcera) é uma LESÃO e vive na tabela abaixo.
     Sem esta separação, uma gastrite difusa contava como lesão no ADR. */
  aspeto            text references public.endo_achados(codigo) on delete restrict,

  /* Marco fotografado: a prova de que o exame chegou onde o relatório diz. */
  fotografada       boolean not null default false,
  nota              text,
  created_at        timestamptz not null default now(),

  constraint endo_exame_localizacao_unica unique (exame_id, localizacao)
);

comment on table public.endo_exame_localizacoes is
  'O que foi visitado e o aspeto de cada segmento. O `aspeto` e o achado DIFUSO; o que e focal e uma lesao, na tabela endo_lesoes.';

create index if not exists idx_endo_exame_loc_exame on public.endo_exame_localizacoes (exame_id);


-- ---------------------------------------------------------------------------
-- 3. A PREPARAÇÃO INTESTINAL, POR SEGMENTO
--
-- A escala de Boston pontua POR SEGMENTO e o total é a soma. Guardar só o total
-- tornaria impossível saber se uma preparação de 6 era uniforme ou péssima num
-- segmento e boa nos outros — e é isso que muda a decisão de repetir o exame.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_exame_preparacao (
  id                uuid primary key default gen_random_uuid(),
  exame_id          uuid not null references public.endo_exames(id) on delete cascade,
  segmento          text not null references public.endo_segmentos(codigo) on delete restrict,
  classificacao     text not null references public.endo_classificacoes(codigo) on delete restrict,
  /* O valor da escala. Só faz sentido para classificação NUMÉRICA, e é o que a
     restrição abaixo impõe. */
  valor             smallint not null,
  created_at        timestamptz not null default now(),

  constraint endo_exame_preparacao_unica unique (exame_id, segmento, classificacao)
);

comment on table public.endo_exame_preparacao is
  'Preparacao intestinal por segmento. A Boston pontua por segmento e o total e a soma - guardar so o total perderia a informacao que decide repetir o exame.';

create index if not exists idx_endo_exame_prep_exame on public.endo_exame_preparacao (exame_id);


-- ---------------------------------------------------------------------------
-- 4. AS LESÕES
--
-- Uma linha por lesão. **O ADR é uma contagem de lesões sobre exames, e nada
-- mais** — se estivesse dentro de um jsonb, o indicador calcular-se-ia no cliente
-- e dependeria de quem o consulta. Com uma tabela é um `count(*)`.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_lesoes (
  id                uuid primary key default gen_random_uuid(),
  exame_id          uuid not null references public.endo_exames(id) on delete cascade,
  localizacao       text not null references public.endo_localizacoes(codigo) on delete restrict,
  achado            text not null references public.endo_achados(codigo) on delete restrict,

  /* Para distinguir «pólipo 1» de «pólipo 2» no mesmo segmento. Sem isto, dois
     pólipos no mesmo sítio são indistinguíveis nas amostras e no resultado. */
  numero            smallint not null default 1,

  tamanho_mm        smallint check (tamanho_mm is null or tamanho_mm >= 0),

  /* Removida: é o que separa uma lesão detetada de uma lesão tratada. O ADR conta
     as DETETADAS; a taxa de remoção conta as removidas. */
  removida          boolean not null default false,

  nota              text,
  created_at        timestamptz not null default now(),

  constraint endo_lesoes_numero_unico unique (exame_id, localizacao, achado, numero)
);

comment on table public.endo_lesoes is
  'Uma linha por lesao. O ADR e um count(*) sobre esta tabela - por isso e uma tabela e nao um jsonb.';

create index if not exists idx_endo_lesoes_exame on public.endo_lesoes (exame_id);
create index if not exists idx_endo_lesoes_local on public.endo_lesoes (localizacao);


-- ---------------------------------------------------------------------------
-- 5. AS CLASSIFICAÇÕES DE CADA LESÃO — E A RESTRIÇÃO QUE FAZ A REGRA VALER
--
-- `valor_codigo` para as categóricas, `valor_numero` para as numéricas. Os dois
-- existem na mesma linha porque um exame tem ambos os tipos de classificação — o
-- que NÃO pode existir é o par errado.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_lesao_classificacoes (
  id                uuid primary key default gen_random_uuid(),
  lesao_id          uuid not null references public.endo_lesoes(id) on delete cascade,
  classificacao     text not null references public.endo_classificacoes(codigo) on delete restrict,

  valor_codigo      text,
  valor_numero      smallint,

  /* A VERSÃO DA NORMA, COPIADA NO REGISTO e não lida por junção.
     Parece duplicação; é deliberado. Se a norma mudar e o dicionário for
     atualizado, um exame antigo tem de continuar a dizer COM QUE NORMA foi
     classificado — e uma junção daria a versão de hoje. É a regra 4 do
     dicionário a ser cumprida onde ela importa. */
  versao            text not null,

  nota              text,
  created_at        timestamptz not null default now(),

  constraint endo_lesao_classificacao_unica unique (lesao_id, classificacao)
);

comment on table public.endo_lesao_classificacoes is
  'Classificacoes de uma lesao. Uma categorica usa valor_codigo; uma numerica usa valor_numero. A restricao abaixo impede o par errado - e e ela que faz a regra valer nos DADOS, e nao so no dicionario.';

create index if not exists idx_endo_lesao_cls_lesao on public.endo_lesao_classificacoes (lesao_id);
create index if not exists idx_endo_lesao_cls_class on public.endo_lesao_classificacoes (classificacao);


/* ---------------------------------------------------------------------------
   5a. A RESTRIÇÃO — o ponto mais importante desta migração
   ---------------------------------------------------------------------------
   Escrita como FUNÇÃO e não como `check` inline, por uma razão prática: um
   `check` não pode consultar outra tabela, e é preciso saber o TIPO da
   classificação, que vive em `endo_classificacoes`. Um gatilho pode.

   A alternativa — repetir o tipo numa coluna desta tabela — seria uma segunda
   cópia da mesma verdade, e a cópia que ninguém corre é a que fica errada.

   A função verifica TRÊS coisas, e a terceira é a que se esquece:
     1. classificações categóricas exigem `valor_codigo` e proíbem `valor_numero`;
     2. classificações numéricas exigem `valor_numero` e proíbem `valor_codigo`;
     3. o código/número usado EXISTE no dicionário daquela classificação.
   --------------------------------------------------------------------------- */
create or replace function clinia.validar_classificacao_de_lesao()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tipo text;
  v_codigo_valido boolean;
  v_numero_valido boolean;
begin
  select c.tipo into v_tipo
    from public.endo_classificacoes c
   where c.codigo = new.classificacao;

  if v_tipo is null then
    raise exception 'A classificacao "%" nao existe no dicionario.', new.classificacao
      using errcode = 'foreign_key_violation';
  end if;

  if v_tipo = 'categorico' then
    /* A ORDEM DESTAS DUAS VERIFICAÇÕES IMPORTA, e não é arbitrária.
       Quando uma categórica traz um NÚMERO e nenhum código — que é o defeito
       original, «Paris com um 3 ao lado» — as duas condições falham. Se a falta
       de código fosse verificada primeiro, a mensagem seria «exige um codigo», e
       o número que lá está não era sequer mencionado.

       Verifica-se primeiro o NÚMERO, porque é o erro mais grave: uma categoria
       com um número é o que produz um relatório com um valor inventado. A
       mensagem tem de dizer isso, e não outra coisa.

       Isto foi descoberto por EXECUÇÃO, não por leitura: o teste da base de dados
       exigia a mensagem certa e apanhou a ordem errada. Sem ele, as duas ordens
       pareciam igualmente boas — e uma delas esconde o erro que interessa. */
    if new.valor_numero is not null then
      raise exception 'A classificacao "%" e CATEGORICA e nao pode ter um numero (valor_numero = %). '
        'Um codigo categorico nunca produz um numero - ve a migracao 0032.',
        new.classificacao, new.valor_numero
        using errcode = 'check_violation';
    end if;
    if new.valor_codigo is null then
      raise exception 'A classificacao "%" e categorica e exige um codigo (valor_codigo).', new.classificacao
        using errcode = 'check_violation';
    end if;

    select exists (
      select 1 from public.endo_classificacao_valores v
       where v.classificacao = new.classificacao and v.codigo = new.valor_codigo
    ) into v_codigo_valido;

    if not v_codigo_valido then
      raise exception 'O codigo "%" nao existe na classificacao categorica "%".',
        new.valor_codigo, new.classificacao using errcode = 'check_violation';
    end if;

  else
    /* O espelho do caso acima: primeiro o código indevido, depois o valor em
       falta. Uma numérica com um código de categoria tem o erro mais grave. */
    if new.valor_codigo is not null then
      raise exception 'A classificacao "%" e NUMERICA e nao pode ter um codigo de categoria (valor_codigo = %).',
        new.classificacao, new.valor_codigo
        using errcode = 'check_violation';
    end if;
    if new.valor_numero is null then
      raise exception 'A classificacao "%" e numerica e exige um valor (valor_numero).', new.classificacao
        using errcode = 'check_violation';
    end if;

    select exists (
      select 1 from public.endo_classificacao_escala e
       where e.classificacao = new.classificacao and e.valor = new.valor_numero
    ) into v_numero_valido;

    if not v_numero_valido then
      raise exception 'O valor % nao existe na escala da classificacao "%".',
        new.valor_numero, new.classificacao using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

comment on function clinia.validar_classificacao_de_lesao() is
  'Impoe nos DADOS a regra que o dicionario impoe na sua forma: uma classificacao categorica nunca tem numero, e uma numerica nunca tem codigo. Verifica tambem que o valor existe no dicionario.';

drop trigger if exists t_endo_lesao_cls_valida on public.endo_lesao_classificacoes;
create trigger t_endo_lesao_cls_valida
  before insert or update on public.endo_lesao_classificacoes
  for each row execute function clinia.validar_classificacao_de_lesao();


/* ---------------------------------------------------------------------------
   5b. A MESMA REGRA NA PREPARAÇÃO
   ---------------------------------------------------------------------------
   A preparação usa uma escala numérica (Boston). Sem uma verificação, podia
   gravar-se um valor de uma classificação categórica — ou um valor que não
   existe na escala. É a mesma regra, num sítio diferente, e por isso é a mesma
   função adaptada.
   --------------------------------------------------------------------------- */
create or replace function clinia.validar_preparacao_do_exame()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tipo text;
  v_valido boolean;
begin
  select c.tipo into v_tipo
    from public.endo_classificacoes c
   where c.codigo = new.classificacao;

  if v_tipo is null then
    raise exception 'A classificacao "%" nao existe no dicionario.', new.classificacao;
  end if;

  if v_tipo <> 'numerico' then
    raise exception 'A preparacao intestinal usa uma escala NUMERICA, e "%" e categorica.', new.classificacao
      using errcode = 'check_violation';
  end if;

  select exists (
    select 1 from public.endo_classificacao_escala e
     where e.classificacao = new.classificacao and e.valor = new.valor
  ) into v_valido;

  if not v_valido then
    raise exception 'O valor % nao existe na escala da classificacao "%".',
      new.valor, new.classificacao using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists t_endo_exame_prep_valida on public.endo_exame_preparacao;
create trigger t_endo_exame_prep_valida
  before insert or update on public.endo_exame_preparacao
  for each row execute function clinia.validar_preparacao_do_exame();


-- ---------------------------------------------------------------------------
-- 6. AS INTERVENÇÕES
-- ---------------------------------------------------------------------------
create table if not exists public.endo_exame_intervencoes (
  id                uuid primary key default gen_random_uuid(),
  exame_id          uuid not null references public.endo_exames(id) on delete cascade,
  intervencao       text not null references public.endo_intervencoes(codigo) on delete restrict,
  localizacao       text references public.endo_localizacoes(codigo) on delete restrict,
  lesao_id          uuid references public.endo_lesoes(id) on delete set null,
  nota              text,
  created_at        timestamptz not null default now()
);

comment on table public.endo_exame_intervencoes is
  'O que se FEZ no exame, e onde. `lesao_id` liga a intervencao a lesao quando ela existe - e o que permite dizer "esta lesao foi removida" sem o deduzir.';

create index if not exists idx_endo_exame_int_exame on public.endo_exame_intervencoes (exame_id);


-- ---------------------------------------------------------------------------
-- 7. AS AMOSTRAS
--
-- `caixa` é o elo para o ciclo do resultado. Sem um identificador por amostra
-- não há como reconciliar o resultado histológico com a lesão — e é esse ciclo
-- que quase nenhum sistema fecha.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_amostras (
  id                uuid primary key default gen_random_uuid(),
  exame_id          uuid not null references public.endo_exames(id) on delete cascade,
  localizacao       text not null references public.endo_localizacoes(codigo) on delete restrict,
  lesao_id          uuid references public.endo_lesoes(id) on delete set null,

  tipo              text not null default 'biopsia'
                    check (tipo in ('biopsia', 'polipectomia', 'citologia', 'outra')),

  /* O número da caixa/recipiente. É por aqui que o resultado volta do
     laboratório, e sem ele não há reconciliação possível. */
  caixa             text,
  descricao         text,

  /* O resultado, quando chega. Fica em jsonb porque a forma depende do
     laboratório e ainda não está fechada — e um esquema inventado agora seria
     pior do que um campo por tipificar quando se souber a forma. */
  resultado         jsonb,
  resultado_em      timestamptz,

  created_at        timestamptz not null default now()
);

comment on table public.endo_amostras is
  'Amostras colhidas. O `caixa` e o elo para o resultado histologico - sem ele nao ha reconciliacao entre o que se colheu e o que o laboratorio devolveu.';

create index if not exists idx_endo_amostras_exame on public.endo_amostras (exame_id);
create index if not exists idx_endo_amostras_lesao on public.endo_amostras (lesao_id);
/* Índice para a pergunta que o ciclo do resultado faz: que amostras estão sem
   resultado? É um índice parcial porque as com resultado são a maioria e não
   interessam para esta consulta. */
create index if not exists idx_endo_amostras_sem_resultado
  on public.endo_amostras (exame_id) where resultado is null;


-- ---------------------------------------------------------------------------
-- 8. updated_at
-- ---------------------------------------------------------------------------
drop trigger if exists t_endo_exames_updated_at on public.endo_exames;
create trigger t_endo_exames_updated_at
  before update on public.endo_exames
  for each row execute function clinia.set_updated_at();


-- ---------------------------------------------------------------------------
-- 9. RLS, PRIVILÉGIOS E AUDITORIA
--
-- ESTAS TABELAS SÃO DADOS CLÍNICOS E SÃO POR CLÍNICA — ao contrário do
-- dicionário, que é global e só de leitura. Aqui o RLS tem de filtrar por
-- `clinica_id`, e é o que a política faz.
--
-- A lista constrói-se do catálogo, e não à mão: uma tabela nova não fica de fora.
-- A lista fixa do 0010 já obrigou a acrescentar tabelas à mão uma vez.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  for t in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and c.relname in ('endo_exames', 'endo_exame_localizacoes', 'endo_exame_preparacao',
                         'endo_lesoes', 'endo_lesao_classificacoes', 'endo_exame_intervencoes',
                         'endo_amostras')
  loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated;', t);
    execute format('grant all on public.%I to service_role;', t);
  end loop;
end $$;

/* O exame filtra por clínica. As tabelas filhas filtram pelo exame, e não pelo
   clinica_id — não têm essa coluna (seria uma terceira cópia da mesma verdade, e
   a que ninguém atualiza). A política usa `exists` sobre o exame. */
drop policy if exists endo_exames_por_clinica on public.endo_exames;
create policy endo_exames_por_clinica on public.endo_exames
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id())
  with check (clinica_id = clinia.current_clinica_id());

do $$
declare
  t text;
  filhas text[] := array['endo_exame_localizacoes', 'endo_exame_preparacao', 'endo_lesoes',
                         'endo_exame_intervencoes', 'endo_amostras'];
begin
  foreach t in array filhas loop
    execute format('drop policy if exists %1$s_do_exame on public.%1$I;', t);
    execute format(
      'create policy %1$s_do_exame on public.%1$I for all to authenticated
         using (exists (select 1 from public.endo_exames e
                         where e.id = %1$I.exame_id
                           and e.clinica_id = clinia.current_clinica_id()))
         with check (exists (select 1 from public.endo_exames e
                              where e.id = %1$I.exame_id
                                and e.clinica_id = clinia.current_clinica_id()));', t);
  end loop;

  /* As classificações da lesão filtram pela lesão, que filtra pelo exame. */
  execute 'drop policy if exists endo_lesao_classificacoes_da_lesao on public.endo_lesao_classificacoes;';
  execute 'create policy endo_lesao_classificacoes_da_lesao on public.endo_lesao_classificacoes
             for all to authenticated
             using (exists (select 1 from public.endo_lesoes l
                             join public.endo_exames e on e.id = l.exame_id
                            where l.id = endo_lesao_classificacoes.lesao_id
                              and e.clinica_id = clinia.current_clinica_id()))
             with check (exists (select 1 from public.endo_lesoes l
                                  join public.endo_exames e on e.id = l.exame_id
                                 where l.id = endo_lesao_classificacoes.lesao_id
                                   and e.clinica_id = clinia.current_clinica_id()));';
end $$;

/* Auditoria no exame e nas lesões: são as tabelas onde o histórico é obrigatório.
   Uma lesão que desaparece de um exame é uma alteração ao registo clínico. */
do $$
declare
  t text;
  tabelas text[] := array['endo_exames', 'endo_lesoes', 'endo_lesao_classificacoes', 'endo_amostras'];
begin
  foreach t in array tabelas loop
    execute format('drop trigger if exists t_audit_%1$s on public.%1$I;', t);
    execute format(
      'create trigger t_audit_%1$s after insert or update or delete on public.%1$I
         for each row execute function clinia.auditar();', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 10. VERIFICAÇÃO — a migração não confia em si própria
--
-- A verificação que importa não é «correu». É que a restrição RECUSE mesmo o que
-- deve recusar. Uma restrição escrita e não testada é uma restrição que se
-- acredita ter.
-- ---------------------------------------------------------------------------
do $$
declare
  v_faltam text;
  v_sem_rls text;
  v_sem_auditoria text;
begin
  /* 10a. As sete tabelas existem. */
  select string_agg(x, ', ') into v_faltam
    from unnest(array['endo_exames', 'endo_exame_localizacoes', 'endo_exame_preparacao',
                      'endo_lesoes', 'endo_lesao_classificacoes', 'endo_exame_intervencoes',
                      'endo_amostras']) x
   where not exists (
     select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = x and c.relkind in ('r', 'p')
   );

  if v_faltam is not null then
    raise exception 'Faltam tabelas do exame: %', v_faltam;
  end if;

  /* 10b. RLS em todas. Uma tabela de dados clínicos sem RLS é uma fuga. */
  select string_agg(c.relname, ', ') into v_sem_rls
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relname in ('endo_exames', 'endo_exame_localizacoes', 'endo_exame_preparacao',
                       'endo_lesoes', 'endo_lesao_classificacoes', 'endo_exame_intervencoes',
                       'endo_amostras')
     and not c.relrowsecurity;

  if v_sem_rls is not null then
    raise exception 'Tabelas do exame sem RLS ativo: %', v_sem_rls;
  end if;

  /* 10c. O gatilho da regra central está criado. Sem ele, o ecrã podia gravar um
     número numa classificação categórica e nada o impedia. */
  if not exists (
    select 1 from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
     where c.relname = 'endo_lesao_classificacoes' and t.tgname = 't_endo_lesao_cls_valida'
  ) then
    raise exception 'O gatilho que impede um numero numa classificacao categorica nao foi criado.';
  end if;

  /* 10d. AUDITORIA. Só se a função existir — noutra base de dados pode não haver,
     e não é esta migração que a cria. */
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'clinia' and p.proname = 'auditar') then
    select string_agg(c.relname, ', ') into v_sem_auditoria
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in ('endo_exames', 'endo_lesoes', 'endo_lesao_classificacoes', 'endo_amostras')
       and not exists (
         select 1 from pg_trigger t
          where t.tgrelid = c.oid and t.tgname = 't_audit_' || c.relname
       );

    if v_sem_auditoria is not null then
      raise exception 'Tabelas do exame sem auditoria: %', v_sem_auditoria;
    end if;
  end if;

  raise notice 'Exame de endoscopia criado. A regra categorico-nunca-numero passa a ser imposta tambem nos dados, e nao so no dicionario.';
end $$;


-- ----------------------------------------------------------------------------
-- 0034_relatorio_de_endoscopia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0034 — O RELATÓRIO DE ENDOSCOPIA
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE UMA MIGRAÇÃO SÓ PARA ACRESCENTAR UM VALOR A UM TIPO
-- ─────────────────────────────────────────────────────────────────────────────
-- O PostgreSQL recusa usar um valor de enum na MESMA transação em que o cria:
--
--     ERROR: unsafe use of new value "relatorio_endoscopia" of enum type
--
-- E o ficheiro de instalação corre TODO dentro de uma transação — do `begin` da
-- linha 33 ao `commit` do fim. Um valor acrescentado e usado na mesma migração
-- daria «unsafe use of new value», e a instalação INTEIRA caía.
--
-- Isto já está explicado na migração 0001, a propósito do papel `socio`, e é a
-- razão pela qual aquele valor vive na 0001b e não na 0001. Aqui é o mesmo
-- problema, e leva a mesma solução: o valor nasce nesta migração, e é USADO na
-- seguinte.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE UM TIPO PRÓPRIO, E NÃO `outro`
-- ─────────────────────────────────────────────────────────────────────────────
-- O enum já tem `nota_clinica`, `relatorio_alta`, `relatorio_medico_legal`,
-- `relatorio_seguradora`, `carta_medico_assistente`, `declaracao_presenca` e
-- `outro`. Podia usar-se `outro` e ficar tudo resolvido hoje.
--
-- Não se fez, e a razão é concreta: **o tipo decide os campos obrigatórios**. É
-- o que está escrito na própria definição da tabela `relatorios` — «Estrutura do
-- relatório, para os campos obrigatórios por tipo (seguradora, médico-legal)
-- serem validáveis». Um relatório de endoscopia tem obrigatórios que nenhum
-- outro tem: a preparação intestinal, o tempo de retirada, a intubação cecal, os
-- marcos fotografados.
--
-- Com `outro`, esses obrigatórios não teriam onde ser declarados, e a validação
-- por tipo deixava de os apanhar. **Um relatório de colonoscopia sem tempo de
-- retirada é indistinguível de um completo** — e é isso que o tipo existe para
-- impedir.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTA SOBRE ENUMS EM POSTGRESQL
-- ─────────────────────────────────────────────────────────────────────────────
-- `add value if not exists` torna a migração repetível, como todas as outras do
-- projeto. Sem o `if not exists`, correr a instalação duas vezes falharia — e a
-- instalação é feita para poder correr duas vezes.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. O TIPO DE RELATÓRIO
--
-- `after 'declaracao_presenca'` coloca o valor antes de `outro`, que é onde faz
-- sentido: `outro` é o resto, e o resto vem no fim. A ordem de um enum é a ordem
-- em que os valores aparecem num seletor.
-- ---------------------------------------------------------------------------
alter type public.relatorio_tipo add value if not exists 'relatorio_endoscopia'
  after 'declaracao_presenca';


-- ---------------------------------------------------------------------------
-- 2. VERIFICAÇÃO — a migração não confia em si própria
--
-- Uma migração de uma linha é a que mais parece não precisar de verificação, e é
-- onde uma falha silenciosa custa mais: se o valor não entrar, a migração
-- seguinte — que o USA — rebenta ao instalar, e a mensagem aponta para a
-- migração errada.
--
-- Esta verificação NÃO usa o valor. Usá-lo aqui seria o defeito que a migração
-- existe para evitar: o PostgreSQL recusa ler um valor de enum na mesma
-- transação em que foi criado, e `= 'relatorio_endoscopia'` é uma leitura.
-- Verifica-se a PRESENÇA no catálogo, que é seguro.
-- ---------------------------------------------------------------------------
do $$
declare
  v_existe boolean;
begin
  select exists (
    select 1
      from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public'
       and t.typname = 'relatorio_tipo'
       and e.enumlabel = 'relatorio_endoscopia'
  ) into v_existe;

  if not v_existe then
    raise exception 'O valor relatorio_endoscopia nao entrou no tipo relatorio_tipo. A migracao seguinte, que o usa, rebentaria na instalacao.';
  end if;

  raise notice 'Tipo de relatorio: relatorio_endoscopia acrescentado. Na proxima migracao e que pode ser USADO - o PostgreSQL nao deixa usar um valor de enum na transacao que o cria.';
end $$;


-- ----------------------------------------------------------------------------
-- 0035_direitos_do_titular.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0030 — DIREITOS DO TITULAR DOS DADOS
-- ============================================================================
--
-- O QUE FALTAVA, E PORQUE NÃO SE RESOLVE COM UM DELETE
-- ============================================================================
--
-- O programa tem uma regra deliberada, na migração 0011:
--
--     clinia.arquivar_em_vez_de_apagar()
--     'Converte DELETE em arquivo (arquivado_em). Histórico clínico não se apaga.'
--
-- **Um `delete` num utente não o apaga: arquiva-o.** E está certo — protege o
-- histórico de um erro acidental. Mas tem uma consequência que ninguém tinha
-- enfrentado:
--
--     **O direito ao apagamento não existe hoje de forma nenhuma.**
--
-- A regra que protege o utente de um erro é a mesma que lhe nega um direito.
-- Esta migração resolve isso, e a resolução não é apagar mais: é perceber o que
-- a lei manda apagar.
--
-- ============================================================================
-- APAGAR O QUÊ, EXATAMENTE
-- ============================================================================
--
-- Há uma tensão real, e não se resolve com código:
--
--   · **RGPD art. 17** — o titular tem direito ao apagamento dos seus dados.
--   · **Conservação do processo clínico** — a lei obriga a guardar o registo
--     clínico durante anos, e o RGPD art. 17.º/3/b) prevê expressamente essa
--     exceção.
--
-- As duas coisas ao mesmo tempo só são possíveis se se separar o que nelas se
-- mistura:
--
--   **A IDENTIDADE sai. O ATO CLÍNICO fica.**
--
-- O que sai é o que identifica a pessoa: nome, NIF, número de utente do SNS,
-- contactos, morada, data de nascimento. O que fica é o registo do que lhe foi
-- feito — diagnóstico, medições, sessões, plano — ligado por `utente_id`.
--
-- E isto é possível **precisamente porque o esquema foi bem desenhado**: as 29
-- tabelas clínicas ligam-se por `utente_id` e nenhuma delas duplica a identidade.
-- Confirmado no catálogo: só `utentes` e `utente_contactos` têm campos de
-- identidade. Se os episódios tivessem uma cópia do nome — como eu cheguei a
-- pensar, por um erro de leitura meu — limpar o `utentes` deixaria o nome dentro
-- dos episódios, e o direito ficaria por cumprir sem ninguém dar por isso.
--
-- ============================================================================
-- E O QUE **NÃO** SE APAGA, MESMO PARECENDO IDENTIDADE
-- ============================================================================
--
-- `utentes` guarda `alergias` e `alertas`. **Não se tocam**, e a razão não é
-- jurídica, é clínica:
--
--   Se se apagarem e o utente voltar à clínica — e o `utente_id` continua a
--   existir, porque é o pseudónimo — o programa deixa de avisar que ele é
--   alérgico à penicilina.
--
-- **Um apagamento que cria um risco clínico não é conformidade: é um defeito
-- novo.** Uma alergia é um dado de saúde (art. 9), e o tratamento continua
-- lícito pelo art. 9.º/2/h) — prestação de cuidados de saúde. O que o art. 17
-- manda apagar é a identidade, e uma alergia não identifica ninguém.
--
-- E o `numero_utente` também fica: é um número sequencial da clínica, não
-- identifica a pessoa na rua, e é a chave que liga a ficha nova à antiga se ela
-- voltar.
--
-- ============================================================================
-- O QUE ESTA MIGRAÇÃO **NÃO** FAZ
-- ============================================================================
--
-- **Não decide prazos de conservação.** Não sei o prazo legal aplicável e não o
-- vou inventar: um número inventado num sistema de saúde é pior do que nenhum,
-- porque cria a aparência de conformidade e ninguém o vai verificar. Fica uma
-- tabela de configuração com o campo pronto e o valor por omissão a NULL — e
-- NULL significa «não apagar automaticamente», que é o lado seguro do erro.
--
-- **Não apaga nada automaticamente.** Esta migração dá o instrumento; quem o usa
-- é uma pessoa, com um pedido concreto à frente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. OS PEDIDOS DO TITULAR
-- ---------------------------------------------------------------------------
-- Um direito exercido tem de deixar rasto: quem pediu, quando, o que foi feito e
-- por quem. Sem isto, a clínica não consegue provar a um regulador que cumpriu.
--
-- E há uma razão prática: um pedido de apagamento chega por telefone ou por
-- email. Se não houver onde o registar, alguém executa-o e não fica nada.
do $$ begin
  create type public.pedido_titular_tipo as enum (
    'acesso',         -- cópia dos dados (art. 15)
    'retificacao',    -- corrigir (art. 16)
    'apagamento',     -- apagar (art. 17)
    'portabilidade',  -- receber em formato reutilizável (art. 20)
    'limitacao',      -- limitar o tratamento (art. 18)
    'oposicao'        -- opor-se (art. 21)
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.pedido_titular_estado as enum (
    'recebido',
    'em_analise',
    'executado',
    'recusado',       -- com motivo escrito: há pedidos que a lei manda recusar
    'cancelado'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.pedidos_titular (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas(id) on delete restrict,
  utente_id      uuid not null references public.utentes(id) on delete restrict,

  tipo           public.pedido_titular_tipo not null,
  estado         public.pedido_titular_estado not null default 'recebido',

  -- Como chegou o pedido. Não é burocracia: uma recusa tem de ser fundamentada, e
  -- a fundamentação depende de se o pedido veio do titular ou de outra pessoa.
  canal          text,                    -- 'telefone', 'email', 'balcao', 'carta'
  pedido_em      timestamptz not null default now(),
  descricao      text,                    -- o que o titular pediu, por palavras dele

  -- Quem tratou. `profissional` e não `perfil`: é uma pessoa, e responde por isto.
  tratado_por    uuid references public.perfis(id) on delete set null,
  tratado_em     timestamptz,
  resposta       text,                    -- o que se respondeu ao titular

  -- Quando é que a lei manda responder: um mês, prorrogável (art. 12.º/3).
  prazo_resposta date,

  created_at     timestamptz not null default now(),

  constraint pedidos_titular_resposta_coerente check (
    (estado = 'executado' and tratado_em is not null)
    or (estado = 'recusado' and resposta is not null)
    or estado in ('recebido', 'em_analise', 'cancelado')
  )
);

comment on table public.pedidos_titular is
  'Pedidos de titular de dados (RGPD arts. 15 a 21). Um direito exercido tem de deixar rasto: quem pediu, quando, o que foi feito e por quem. Sem isto, a clinica nao consegue provar a um regulador que cumpriu.';

comment on column public.pedidos_titular.prazo_resposta is
  'Um mes, prorrogavel por dois, a contar do pedido (RGPD art. 12.o/3). Fica gravado no momento do pedido e nao se recalcula: a data que conta e a que se prometeu ao titular.';

create index if not exists idx_pedidos_titular_abertos
  on public.pedidos_titular (clinica_id, prazo_resposta)
  where estado in ('recebido', 'em_analise');

create index if not exists idx_pedidos_titular_utente
  on public.pedidos_titular (utente_id, pedido_em desc);

-- ---------------------------------------------------------------------------
-- 2. O PRAZO DE CONSERVAÇÃO — CONFIGURÁVEL, E POR OMISSÃO NULO
-- ---------------------------------------------------------------------------
-- **O valor por omissão é `null`, e `null` quer dizer «não apagar
-- automaticamente».** É o lado seguro do erro: um sistema que apaga a mais
-- destrói o processo clínico de alguém; um que apaga a menos fica com dados que
-- devia ter apagado, e isso corrige-se depois.
--
-- Não sei o prazo legal aplicável e **não o vou inventar**. Quem o souber —
-- com o jurista da clínica — escreve-o aqui, e a partir daí o programa pode
-- avisar. Ver `docs/referencia/conservacao-e-apagamento.md`.
alter table public.clinicas
  add column if not exists conservacao_anos integer,
  add column if not exists conservacao_fundamento text;

comment on column public.clinicas.conservacao_anos is
  'Anos de conservacao do processo clinico APOS O ULTIMO ATO. NULL = nao apagar automaticamente (por omissao). O valor tem de vir do jurista da clinica: um prazo inventado num sistema de saude e pior do que nenhum, porque cria aparencia de conformidade.';

comment on column public.clinicas.conservacao_fundamento is
  'A norma em que o prazo se baseia. Obrigatorio quando conservacao_anos esta preenchido, e verificado por restricao: um prazo sem fundamento escrito e um numero que ninguem sabe de onde veio.';

do $$ begin
  alter table public.clinicas
    add constraint clinicas_conservacao_com_fundamento check (
      conservacao_anos is null
      or (conservacao_anos > 0 and conservacao_anos <= 99
          and conservacao_fundamento is not null
          and length(btrim(conservacao_fundamento)) > 10)
    );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 3. O APAGAMENTO POR PSEUDONIMIZAÇÃO
-- ---------------------------------------------------------------------------
create or replace function clinia.apagar_dados_do_titular(
  p_utente  uuid,
  p_pedido  uuid default null,
  p_motivo  text default null
)
returns table (
  apagado_id      uuid,     -- o utente, que continua a existir como pseudonimo
  contactos       integer,
  pedido_id       uuid,
  campos_limpos   text[]
)
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
declare
  v_clinica   uuid;
  v_utente    public.utentes;
  v_contactos integer := 0;
  v_pedido    uuid := p_pedido;
  v_limpos    text[] := '{}';
begin
  /* QUEM PODE FAZER ISTO. Um apagamento é irreversível e é uma decisão com
     consequências legais: quem o executa responde por ele. Só administrador ou
     gestão, e o mesmo critério que a migração 0025 passou a exigir no
     consentimento — a autorização vive na base de dados, não no ecrã. */
  if not clinia.e_admin() then
    raise exception
      'So um administrador ou a gestao podem executar um pedido de apagamento. E uma decisao com consequencias legais e alguem responde por ela.';
  end if;

  select u.clinica_id into v_clinica from public.utentes u where u.id = p_utente;
  if v_clinica is null then
    raise exception 'O utente % nao existe.', p_utente;
  end if;
  if v_clinica <> clinia.current_clinica_id() then
    raise exception 'Esse utente nao e desta clinica.';
  end if;

  select * into v_utente from public.utentes where id = p_utente;

  /* Já foi apagado? Então não se faz nada, e diz-se. Executar duas vezes não é
     um erro, mas também não pode parecer que se apagou algo novo. */
  if v_utente.arquivado_motivo like 'RGPD%' then
    raise exception 'Os dados deste utente ja foram apagados (%). Nao ha nada a fazer.', v_utente.arquivado_motivo;
  end if;

  /* -------------------------------------------------------------------------
     A IDENTIDADE SAI.
     -------------------------------------------------------------------------
     Cada campo é limpo com um marcador que se percebe ao ler a ficha. `null`
     seria mais limpo, mas quem abrir o processo daqui a anos tem de perceber
     PORQUE é que o nome está vazio — senão parece um erro do programa. */
  update public.utentes set
    nome              = '[apagado a pedido do titular]',
    nome_preferido    = null,
    data_nascimento   = null,
    sexo              = null,
    nif               = null,
    numero_sns        = null,
    numero_utente_sns = null,
    email             = null,
    telemovel         = null,
    telefone          = null,
    morada            = null,
    codigo_postal     = null,
    localidade        = null,
    numero_apolice    = null,
    notas             = null,
    /* arquivado_em E arquivado_motivo FICAM. O utente sai da lista ativa — é o
       que se quer — e o motivo diz o que aconteceu. Sem o motivo, quem olhar
       para a ficha dentro de dois anos vê um utente arquivado sem saber porquê. */
    arquivado_em      = coalesce(v_utente.arquivado_em, now()),
    arquivado_motivo  = 'RGPD art. 17 - apagamento a pedido do titular'
  where id = p_utente;

  v_limpos := array['nome','nome_preferido','data_nascimento','sexo','nif',
    'numero_sns','numero_utente_sns','email','telemovel','telefone','morada',
    'codigo_postal','localidade','numero_apolice','notas'];

  /* E OS CONTACTOS SAEM INTEIROS.
     Os contactos de familiares são dados de OUTRA pessoa, que nunca deu
     consentimento para nada. Apagar o utente e deixar o telefone da filha dele
     é guardar dados de alguém que não pediu nada e não sabe que estão aqui. */
  with apagados as (
    update public.utente_contactos set
      nome           = '[apagado a pedido do titular]',
      telefone       = null,
      email          = null,
      notas          = null,
      pode_contactar = false
    where utente_id = p_utente
    returning 1
  )
  select count(*)::integer into v_contactos from apagados;

  /* -------------------------------------------------------------------------
     E O PEDIDO FICA REGISTADO.
     ------------------------------------------------------------------------- */
  if v_pedido is null then
    insert into public.pedidos_titular (clinica_id, utente_id, tipo, estado, canal, descricao)
    values (v_clinica, p_utente, 'apagamento', 'em_analise', 'balcao',
            coalesce(p_motivo, 'Apagamento executado'))
    returning id into v_pedido;
  end if;

  update public.pedidos_titular set
    estado      = 'executado',
    tratado_por = auth.uid(),
    tratado_em  = now(),
    resposta    = coalesce(resposta, 'Dados de identificacao apagados. O processo clinico mantem-se pelo prazo legal de conservacao, sem identificar o titular.')
  where id = v_pedido
    and clinica_id = v_clinica;

  /* E na auditoria, que é o registo que ninguém pode reescrever. */
  insert into public.audit_log (clinica_id, utente_id, ator_id, operacao, entidade, registo_id, detalhe, sucesso)
  values (v_clinica, p_utente, auth.uid(), 'update', 'utentes', p_utente::text,
          jsonb_build_object(
            'acao', 'apagamento_rgpd',
            'artigo', 'RGPD art. 17',
            'campos_limpos', to_jsonb(v_limpos),
            'contactos_limpos', v_contactos,
            'pedido', v_pedido,
            'motivo', p_motivo),
          true);

  return query select p_utente, v_contactos, v_pedido, v_limpos;
end $$;

comment on function clinia.apagar_dados_do_titular(uuid, uuid, text) is
  'Executa o direito ao apagamento (RGPD art. 17) por PSEUDONIMIZACAO: apaga a identidade do utente e dos seus contactos, e mantem o processo clinico ligado por utente_id, pelo prazo legal de conservacao. NAO apaga alergias nem alertas: sao dados de seguranca clinica, e apaga-los criaria um risco para o utente se ele voltar.';

-- ---------------------------------------------------------------------------
-- 4. A PORTABILIDADE (art. 20)
-- ---------------------------------------------------------------------------
-- Devolve tudo o que a clínica tem sobre um utente, num objeto só, pronto a
-- entregar. Um direito que exige pedir a um programador que faça um `select`
-- não é um direito exercível.
create or replace function clinia.exportar_dados_do_titular(p_utente uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, clinia, pg_temp
as $$
declare
  v_clinica uuid;
  v_out     jsonb;
begin
  if not (clinia.e_admin() or clinia.e_clinico()) then
    raise exception 'So um profissional da clinica pode exportar os dados de um utente.';
  end if;

  select u.clinica_id into v_clinica from public.utentes u where u.id = p_utente;
  if v_clinica is null then
    raise exception 'O utente % nao existe.', p_utente;
  end if;
  if v_clinica <> clinia.current_clinica_id() then
    raise exception 'Esse utente nao e desta clinica.';
  end if;

  select jsonb_build_object(
    'exportado_em', now(),
    'formato', 'clinIA - dados do titular (RGPD art. 20)',
    'nota', 'Os dados de identificacao podem estar apagados se o titular ja exerceu o direito ao apagamento. O processo clinico mantem-se pelo prazo legal de conservacao.',

    'identificacao', (select to_jsonb(u) - 'clinica_id' from public.utentes u where u.id = p_utente),
    'contactos',     (select coalesce(jsonb_agg(to_jsonb(c) - 'clinica_id'), '[]'::jsonb)
                        from public.utente_contactos c where c.utente_id = p_utente),
    'episodios',     (select coalesce(jsonb_agg(to_jsonb(e) - 'clinica_id'), '[]'::jsonb)
                        from public.episodios e where e.utente_id = p_utente),
    'diagnosticos',  (select coalesce(jsonb_agg(to_jsonb(d) - 'clinica_id'), '[]'::jsonb)
                        from public.diagnosticos d where d.utente_id = p_utente),
    'sessoes',       (select coalesce(jsonb_agg(to_jsonb(s) - 'clinica_id'), '[]'::jsonb)
                        from public.sessoes s where s.utente_id = p_utente),
    'medicoes',      (select coalesce(jsonb_agg(to_jsonb(m) - 'clinica_id'), '[]'::jsonb)
                        from public.medicoes m where m.utente_id = p_utente),
    'planos',        (select coalesce(jsonb_agg(to_jsonb(p) - 'clinica_id'), '[]'::jsonb)
                        from public.planos p where p.utente_id = p_utente),
    'alergias',      (select coalesce(jsonb_agg(to_jsonb(a) - 'clinica_id'), '[]'::jsonb)
                        from public.utente_alergias a where a.utente_id = p_utente),
    'medicacao',     (select coalesce(jsonb_agg(to_jsonb(m) - 'clinica_id'), '[]'::jsonb)
                        from public.utente_medicacao m where m.utente_id = p_utente),
    'consentimentos',(select coalesce(jsonb_agg(to_jsonb(c) - 'clinica_id'), '[]'::jsonb)
                        from public.consentimentos c where c.utente_id = p_utente),
    /* E O PEDIDO, que é a prova de que o direito foi exercido. */
    'pedidos_titular',(select coalesce(jsonb_agg(to_jsonb(p) - 'clinica_id'), '[]'::jsonb)
                        from public.pedidos_titular p where p.utente_id = p_utente)
  ) into v_out;

  /* A exportação também é uma operação sensível, e fica registada. */
  insert into public.audit_log (clinica_id, utente_id, ator_id, operacao, entidade, registo_id, detalhe, sucesso)
  values (v_clinica, p_utente, auth.uid(), 'exportacao', 'utentes', p_utente::text,
          jsonb_build_object('acao', 'portabilidade_rgpd', 'artigo', 'RGPD art. 20'), true);

  return v_out;
end $$;

comment on function clinia.exportar_dados_do_titular(uuid) is
  'Devolve tudo o que a clinica tem sobre um utente, num objeto JSON pronto a entregar (RGPD art. 20, portabilidade). A exportacao fica registada na auditoria.';

-- ---------------------------------------------------------------------------
-- 5. O PRAZO DE RESPOSTA, CALCULADO NO PEDIDO
-- ---------------------------------------------------------------------------
-- Um mês (art. 12.º/3), gravado quando o pedido entra. Não se recalcula: a data
-- que conta é a que se prometeu ao titular.
create or replace function clinia.prazo_resposta_rgpd()
returns trigger
language plpgsql
as $$
begin
  if new.prazo_resposta is null then
    new.prazo_resposta := (new.pedido_em at time zone 'UTC')::date + interval '1 month';
  end if;
  return new;
end $$;

drop trigger if exists t_pedidos_titular_prazo on public.pedidos_titular;
create trigger t_pedidos_titular_prazo
  before insert on public.pedidos_titular
  for each row execute function clinia.prazo_resposta_rgpd();

-- ---------------------------------------------------------------------------
-- 6. RLS E PRIVILÉGIOS
-- ---------------------------------------------------------------------------
alter table public.pedidos_titular enable row level security;

drop policy if exists pedidos_titular_leitura on public.pedidos_titular;
create policy pedidos_titular_leitura on public.pedidos_titular
  for select to authenticated
  using (clinica_id = clinia.current_clinica_id() and (clinia.e_admin() or clinia.e_clinico()));

drop policy if exists pedidos_titular_escrita on public.pedidos_titular;
create policy pedidos_titular_escrita on public.pedidos_titular
  for all to authenticated
  using (clinica_id = clinia.current_clinica_id() and clinia.e_admin())
  with check (clinica_id = clinia.current_clinica_id() and clinia.e_admin());

grant select, insert, update on public.pedidos_titular to authenticated;
grant all on public.pedidos_titular to service_role;

grant execute on function clinia.apagar_dados_do_titular(uuid, uuid, text) to authenticated;
grant execute on function clinia.exportar_dados_do_titular(uuid) to authenticated;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
-- Com um administrador da clínica:
--
--   1. exportar os dados antes de apagar:
--        select clinia.exportar_dados_do_titular('<utente>');
--
--   2. apagar:
--        select * from clinia.apagar_dados_do_titular('<utente>');
--
--   3. confirmar que a identidade saiu E que o processo ficou:
--        select nome, nif, email, arquivado_motivo from public.utentes where id = '<utente>';
--        select count(*) from public.episodios where utente_id = '<utente>';   -- tem de continuar
--        select count(*) from public.medicoes  where utente_id = '<utente>';   -- idem
--
--   4. e confirmar que as ALERGIAS ficaram (é a verificação de segurança):
--        select count(*) from public.utente_alergias where utente_id = '<utente>';
--
--   5. e que uma receção NÃO consegue apagar:
--        (com sessão de receção) select * from clinia.apagar_dados_do_titular('<utente>');
--        -> tem de recusar
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0035b_funcoes_alcancaveis_pelo_postgrest.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0035 — AS FUNÇÕES QUE A APP CHAMA AO SERVIDOR
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O DEFEITO, COMO ELE APARECEU
-- ─────────────────────────────────────────────────────────────────────────────
-- No ambiente de ensaio, a consola do browser dava isto:
--
--     Failed to load resource: the server responded with a status of 404
--     .../rest/v1/rpc/meus_modulos
--
-- E o sintoma visível: uma clínica de endoscopia abria com o menu do MFR.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE DAVA 404
-- ─────────────────────────────────────────────────────────────────────────────
-- As funções todas do projeto vivem no esquema `clinia` — 74 delas. E a migração
-- 0001 diz, por palavras, o que isso significa:
--
--     'Funções utilitárias da plataforma clinia.ai (não exposto por PostgREST).'
--
-- **O PostgREST só expõe o esquema `public`.** Uma chamada a
-- `/rest/v1/rpc/meus_modulos` procura `public.meus_modulos`, não encontra, e
-- responde 404.
--
-- Durante muito tempo isto não fez diferença: nenhuma aplicação chamava uma
-- função `clinia` por RPC. A lista de ecrãs do perfil vem de uma VISTA, os dados
-- vêm de TABELAS, e as escritas passam por gatilhos. O 404 não existia porque a
-- pergunta não era feita.
--
-- A migração que pôs o menu a depender do produto mudou isso: `app.js` passou a
-- chamar `C.sb.rpc('meus_modulos')`. **E aí a decisão de 0001 deixou de ser
-- verdadeira** — sem que ninguém a revisse, porque nada no ficheiro indicava que
-- alguém iria precisar do contrário.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- E PORQUE É QUE ISSO DAVA O MENU DO MFR, QUE É O QUE PARECE MÁGICA
-- ─────────────────────────────────────────────────────────────────────────────
-- Vale a pena seguir, porque o sintoma não se parece nada com a causa.
--
--  1. `carregarModulos` rebenta com o 404, e `C.modulosAtivos` fica a `null`.
--  2. `C.moduloAtivo` tem uma regra para esse caso: com a lista POR SABER,
--     responde pelos módulos por omissão do PRODUTO. É deliberado — é o que
--     impede uma clínica de abrir sem menu nenhum entre o login e a resposta do
--     servidor.
--  3. Mas o produto também não chegou: `C.definirProduto(ctx.produto || 'rehab')`
--     cai em `'rehab'` enquanto o contexto não vier. E `rehab` traz o `mfr`.
--  4. Resultado: o menu do MFR, numa clínica de endoscopia. **Sem um único erro
--     visível no ecrã** — o erro estava só na consola.
--
-- Uma falha de rede transformada em «esta clínica é de reabilitação».
--
-- ─────────────────────────────────────────────────────────────────────────────
-- A CORREÇÃO: EMBRULHOS EM `public`, E NÃO EXPOR O ESQUEMA `clinia`
-- ─────────────────────────────────────────────────────────────────────────────
-- Há duas maneiras de resolver isto:
--
--   a) expor o esquema `clinia` nas definições de API do Supabase (uma alteração
--      de configuração, no painel, não em SQL);
--   b) criar funções em `public` que chamam as de `clinia` (SQL, e só SQL).
--
-- **Escolheu-se (b), e a razão é concreta: (a) não se pode versionar.** Uma
-- alteração feita à mão no painel de um projeto não existe no ficheiro de
-- instalação, e por isso não se reproduz. O próximo ambiente — o de produção, ou
-- o de outro cliente — nasceria com o mesmo 404, e o defeito voltaria sem que
-- nada no repositório o dissesse.
--
-- Com (b), a correção é SQL. Está no ficheiro de instalação, corre em qualquer
-- projeto, e é repetível.
--
-- E expor `clinia` teria um segundo custo: passariam a estar alcançáveis por
-- HTTP **todas** as 74 funções, incluindo as de auditoria e de assinatura. Os
-- embrulhos expõem quatro, e as que ficam de fora continuam de fora.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- OS EMBRULHOS NÃO ACRESCENTAM PERMISSÕES — E ISSO É DELIBERADO
-- ─────────────────────────────────────────────────────────────────────────────
-- Cada embrulho é `security invoker`, e portanto corre com os privilégios de quem
-- chama. A função de dentro é que decide: as quatro são `security definer`, já
-- verificam os papéis e a clínica, e já têm `grant execute` para `authenticated`.
--
-- O embrulho não afrouxa nada: quem não podia chamar `clinia.xxx` continua a não
-- poder, porque é a função de dentro que recusa. **O embrulho é um endereço, não
-- uma autorização.**
--
-- Escrever os embrulhos como `security definer` seria o erro oposto: passariam a
-- correr com privilégios que ninguém lhes deu, e a verificação de dentro deixaria
-- de ter a quem perguntar.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. OS MÓDULOS DA CLÍNICA — a função que o menu precisa
-- ---------------------------------------------------------------------------
create or replace function public.meus_modulos()
returns table (codigo text, nome text, produto public.produto,
               versao_schema text, icone text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select * from clinia.meus_modulos();
$$;

comment on function public.meus_modulos() is
  'Embrulho de clinia.meus_modulos para o PostgREST, que so expoe o esquema public. Security invoker: quem decide e a funcao de dentro, que ja verifica a clinica.';

grant execute on function public.meus_modulos() to authenticated;


-- ---------------------------------------------------------------------------
-- 2. O CONSENTIMENTO — as três funções que o circuito do consentimento usa
--
-- A app chama-as por RPC desde que o circuito existe, e sofriam do mesmo 404.
-- **Não deu sintoma visível** porque o pedido de consentimento falha com uma
-- mensagem no ecrã, e uma mensagem de erro num ecrã é mais fácil de atribuir a
-- outra coisa do que um menu que aparece com os itens errados.
-- ---------------------------------------------------------------------------
create or replace function public.pedir_consentimento(
  p_utente    uuid,
  p_texto_id  uuid,
  p_canal     public.consentimento_canal,
  p_destino   text,
  p_episodio  uuid default null
)
returns table (pedido_id uuid, token text, expira_em timestamptz)
language sql
volatile
security invoker
set search_path = public, pg_temp
as $$
  select * from clinia.pedir_consentimento(p_utente, p_texto_id, p_canal, p_destino, p_episodio);
$$;

comment on function public.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid) is
  'Embrulho de clinia.pedir_consentimento para o PostgREST.';

grant execute on function public.pedir_consentimento(uuid, uuid, public.consentimento_canal, text, uuid)
  to authenticated;


create or replace function public.cancelar_pedido_consentimento(p_pedido uuid)
returns void
language sql
volatile
security invoker
set search_path = public, pg_temp
as $$
  select clinia.cancelar_pedido_consentimento(p_pedido);
$$;

comment on function public.cancelar_pedido_consentimento(uuid) is
  'Embrulho de clinia.cancelar_pedido_consentimento para o PostgREST.';

grant execute on function public.cancelar_pedido_consentimento(uuid) to authenticated;


create or replace function public.pedir_codigo_para_comunicar(p_pedido uuid)
returns table (codigo text, utente_nome text, canal text, expira_em timestamptz)
language sql
volatile
security invoker
set search_path = public, pg_temp
as $$
  select * from clinia.pedir_codigo_para_comunicar(p_pedido);
$$;

comment on function public.pedir_codigo_para_comunicar(uuid) is
  'Embrulho de clinia.pedir_codigo_para_comunicar para o PostgREST.';

grant execute on function public.pedir_codigo_para_comunicar(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. VERIFICAÇÃO — a migração não confia em si própria
--
-- A verificação que interessa não é «as funções existem em public». É que cada
-- uma delas seja `security invoker`. Um embrulho escrito por engano como
-- `security definer` correria com privilégios que ninguém lhe deu — e a
-- verificação de dentro, que é o que protege o circuito, deixaria de ter a quem
-- perguntar.
--
-- É o género de defeito que passa despercebido: a função funciona, devolve os
-- dados certos, e a autorização é que deixou de existir.
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_definer text;
  v_publicas text[] := array['meus_modulos', 'pedir_consentimento',
                             'cancelar_pedido_consentimento', 'pedir_codigo_para_comunicar'];
begin
  /* 3a. As quatro existem em `public`. */
  select string_agg(f, ', ') into v_falta
    from unnest(v_publicas) f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f
   );

  if v_falta is not null then
    raise exception 'Faltam embrulhos em public: %', v_falta;
  end if;

  /* 3b. E NENHUMA é `security definer`. É esta a verificação que importa. */
  select string_agg(p.proname, ', ') into v_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any(v_publicas)
     and p.prosecdef;   /* true = security definer */

  if v_definer is not null then
    raise exception 'Estes embrulhos em public sao SECURITY DEFINER e deviam ser INVOKER: %. '
      'Um embrulho definer corre com privilegios que ninguem lhe deu.', v_definer;
  end if;

  /* 3c. As funções de dentro continuam a existir. Um embrulho para uma função
     que entretanto desapareceu dá 404 outra vez, e desta vez a procurar no
     sítio errado. */
  select string_agg(f, ', ') into v_falta
    from unnest(v_publicas) f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'clinia' and p.proname = f
   );

  if v_falta is not null then
    raise exception 'Faltam as funcoes de dentro, no esquema clinia: %', v_falta;
  end if;

  raise notice 'Funcoes alcancaveis pelo PostgREST: meus_modulos e o circuito do consentimento. Quatro embrulhos em public, todos security invoker.';
end $$;


-- ----------------------------------------------------------------------------
-- 0036_agendamento_sabe_o_procedimento.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0036 — A MARCAÇÃO PASSA A SABER QUE EXAME É
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O DEFEITO, COMO ELE APARECEU
-- ─────────────────────────────────────────────────────────────────────────────
-- Marcava-se um exame na agenda, abria-se, e não se sabia que exame era.
--
-- A tabela `agendamentos` tem `tipo` e `especialidade`:
--
--   · `tipo` é do tipo `ato_tipo` — 'consulta', 'sessao', 'procedimento'… O valor
--     'procedimento' é o MESMO para uma EDA e para uma colonoscopia. **Não
--     distingue nada do que interessa.**
--
--   · `especialidade` diz 'gastro' — e uma colonoscopia e uma EDA são as duas
--     gastro.
--
-- Ou seja: a marcação não tinha onde guardar o que vai ser feito, e a aplicação
-- não tinha como o saber. **Quem marca uma colonoscopia já sabe que é uma
-- colonoscopia** — a informação perdia-se no momento de marcar, e tinha de ser
-- perguntada outra vez na sala.
--
-- Isto não é um detalhe de arrumação. O dicionário de endoscopia é POR
-- PROCEDIMENTO: uma colonoscopia tem preparação intestinal por segmento, tempo de
-- retirada e marcos a fotografar; uma EDA não tem nenhum dos três. Sem saber o
-- procedimento, não se sabe que campos mostrar.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE UMA COLUNA, E NÃO UMA TABELA DE LIGAÇÃO
-- ─────────────────────────────────────────────────────────────────────────────
-- A tentação é criar uma tabela `endoscopia_agendamento_procedimento` para não
-- tocar numa tabela do núcleo. Não se fez, e a razão é que este não é um dado de
-- módulo: é uma PROPRIEDADE DA MARCAÇÃO, exactamente ao mesmo nível que a
-- especialidade e a duração. Uma marcação que não sabe o que vai ser feito é uma
-- marcação incompleta — e uma tabela de ligação permitiria uma marcação sem
-- procedimento, que é o estado que se quer eliminar.
--
-- É também o que a coluna `procedimento` já é em `endo_exames`: texto que casa com
-- `endo_procedimentos.codigo`. A mesma forma nos dois sítios.
--
-- A coluna fica anulável, e isso é deliberado: as marcações de reabilitação não
-- têm procedimento de endoscopia, e as marcações de endoscopia que já existem não
-- o têm. Obrigar a preencher recusaria as que lá estão — e um NOT NULL numa
-- migração sobre dados existentes é a forma mais rápida de partir uma instalação.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. A COLUNA
--
-- A chave estrangeira só se cria se `endo_procedimentos` existir. Numa base de
-- dados onde o dicionário de endoscopia ainda não entrou (uma instalação de
-- reabilitação, por exemplo), a coluna existe e fica sem referência — e a
-- instalação não rebenta.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name = 'procedimento'
  ) then
    alter table public.agendamentos add column procedimento text;
  end if;

  if exists (
    select 1 from information_schema.tables
     where table_schema = 'public' and table_name = 'endo_procedimentos'
  ) and not exists (
    select 1 from pg_constraint where conname = 'agendamentos_procedimento_fkey'
  ) then
    alter table public.agendamentos
      add constraint agendamentos_procedimento_fkey
      foreign key (procedimento) references public.endo_procedimentos(codigo)
      on delete restrict;
  end if;
end $$;

comment on column public.agendamentos.procedimento is
  'Que exame vai ser feito. Casa com endo_procedimentos.codigo quando o modulo de endoscopia esta instalado. Nulo nas marcacoes que nao sao de endoscopia.';


-- ---------------------------------------------------------------------------
-- 2. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_tem_coluna boolean;
  v_tem_fk boolean;
begin
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name = 'procedimento'
  ) into v_tem_coluna;

  if not v_tem_coluna then
    raise exception 'A coluna agendamentos.procedimento nao foi criada.';
  end if;

  /* Se o dicionário existe, a referência TAMBÉM tem de existir. Uma coluna solta
     aceitaria um código inventado — e «gastroenterologia» não é um procedimento. */
  if exists (select 1 from information_schema.tables
              where table_schema = 'public' and table_name = 'endo_procedimentos') then
    select exists (select 1 from pg_constraint where conname = 'agendamentos_procedimento_fkey')
      into v_tem_fk;

    if not v_tem_fk then
      raise exception 'A coluna existe mas a referencia a endo_procedimentos nao. Um codigo inventado seria aceite.';
    end if;
  end if;

  /* E a coluna TEM de aceitar nulo: as marcações que já existem não têm
     procedimento, e um NOT NULL teria recusado a migração sobre dados reais. */
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name = 'procedimento' and is_nullable = 'NO'
  ) then
    raise exception 'A coluna procedimento ficou NOT NULL — recusaria as marcacoes que ja existem.';
  end if;

  raise notice 'A marcacao passou a poder dizer que exame e: agendamentos.procedimento.';
end $$;


-- ----------------------------------------------------------------------------
-- 0037_marcacao_guarda_a_preparacao.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0037 — A MARCAÇÃO GUARDA A PREPARAÇÃO E A DURAÇÃO DO EXAME
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE ESTES DOIS CAMPOS SÃO DA MARCAÇÃO
-- ─────────────────────────────────────────────────────────────────────────────
-- Numa endoscopia, o que se diz ao doente NO MOMENTO DE MARCAR decide se o exame
-- serve para alguma coisa:
--
--   · A PREPARAÇÃO INTESTINAL. Uma colonoscopia com má preparação não vê nada, e
--     repete-se — com o custo, o tempo e o risco outra vez. As instruções são
--     dadas quando se marca, e ficam guardadas com a marcação para poderem ser
--     reimpressas ou reenviadas. **Sem isto, a clínica reescreve as mesmas
--     instruções de cada vez, ou não as dá.**
--
--   · A DURAÇÃO DO EXAME, que NÃO é o mesmo que a duração da marcação. A marcação
--     ocupa a sala 45 minutos (preparar, sedar, acordar, limpar); o exame em si
--     dura 20. Confundir as duas faz com que a agenda pareça cheia quando não
--     está, ou que se marque mais do que a sala aguenta.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE NÃO SÃO COLUNAS TIPADAS DE ENDOSCOPIA
-- ─────────────────────────────────────────────────────────────────────────────
-- A tentação seria uma tabela `endoscopia_marcacao_detalhe`. Não se fez: os dois
-- são PROPRIEDADES DA MARCAÇÃO — texto a dar ao doente, e quanto tempo o exame
-- ocupa — ao mesmo nível que a sala e a duração. Uma tabela de ligação permitiria
-- uma marcação sem preparação, que é o estado que se quer eliminar.
--
-- A preparação fica em TEXTO LIVRE, e não num catálogo. Um catálogo de preparações
-- exigiria uma tabela de protocolos por clínica, que ainda não existe, e obrigaria
-- a decidir a sua forma sem um caso real. Texto livre hoje, catálogo quando houver
-- mais do que um protocolo para gerir.
--
-- A duração do exame tem de ser MENOR OU IGUAL à da marcação: não pode ser
-- reservada uma sala durante 45 minutos para um exame de 90. A restrição fica na
-- base de dados, onde não depende de ninguém se lembrar.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. AS COLUNAS
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name = 'preparacao_instrucoes'
  ) then
    alter table public.agendamentos add column preparacao_instrucoes text;
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name = 'duracao_exame_minutos'
  ) then
    alter table public.agendamentos add column duracao_exame_minutos smallint;
  end if;
end $$;

comment on column public.agendamentos.preparacao_instrucoes is
  'O que se diz ao doente para se preparar. Dado no momento de marcar, e guardado com a marcacao para poder ser reimpresso ou reenviado.';

comment on column public.agendamentos.duracao_exame_minutos is
  'Quanto tempo ocupa o EXAME, que nao e o mesmo que a duracao da marcacao. A marcacao ocupa a sala (preparar, sedar, acordar); o exame e o que se faz dentro desse tempo.';

/* A duração do exame não pode exceder a da marcação: seria reservar uma sala
   durante 45 minutos para um exame de 90. */
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'agendamentos_duracao_exame_coerente') then
    alter table public.agendamentos
      add constraint agendamentos_duracao_exame_coerente
      check (duracao_exame_minutos is null
             or (duracao_exame_minutos > 0 and duracao_exame_minutos <= duracao_minutos));
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_check boolean;
begin
  select string_agg(c, ', ') into v_falta
    from unnest(array['preparacao_instrucoes', 'duracao_exame_minutos']) c
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'agendamentos'
        and column_name = c
   );

  if v_falta is not null then
    raise exception 'Faltam colunas em agendamentos: %', v_falta;
  end if;

  /* A restrição TEM de existir: sem ela, uma marcação de 45 minutos podia declarar
     um exame de 90 — e a sala estaria reservada para metade do que lá se passa. */
  select exists (select 1 from pg_constraint where conname = 'agendamentos_duracao_exame_coerente')
    into v_check;

  if not v_check then
    raise exception 'A restricao que impede um exame mais longo do que a marcacao nao foi criada.';
  end if;

  /* E as colunas aceitam nulo: as marcações que já existem não têm nenhuma das
     duas, e um NOT NULL teria recusado a migração sobre dados reais. */
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'agendamentos'
       and column_name in ('preparacao_instrucoes', 'duracao_exame_minutos')
       and is_nullable = 'NO'
  ) then
    raise exception 'Uma das colunas ficou NOT NULL — recusaria as marcacoes que ja existem.';
  end if;

  raise notice 'A marcacao passou a guardar a preparacao do doente e a duracao do exame.';
end $$;


-- ----------------------------------------------------------------------------
-- 0038_exame_regista_como_correu.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0038 — O QUE SE USOU, ONDE SE CHEGOU, COMO FOI TOLERADO
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DE ONDE VÊM ESTES CAMPOS
-- ─────────────────────────────────────────────────────────────────────────────
-- De olhar para o que um registo de exame de endoscopia tem de ter, e de o
-- comparar com o que o exame já tinha. Faltavam quatro coisas, e as quatro são do
-- mesmo tipo: **o que se usou e como correu**, que é coisa diferente de **o que se
-- viu** (esse já está nas localizações, nas lesões e nas amostras).
--
--   1. DISPOSITIVO      — com que aparelho se fez. É o que permite responder a
--                         «este colonoscópio está a dar problemas?».
--   2. SEGMENTO ALCANÇADO — o alcance como CÓDIGO, e não só como texto livre.
--   3. TOLERÂNCIA       — como o doente tolerou, que é o que decide a sedação da
--                         próxima vez.
--   4. LIMITAÇÕES       — o que impediu ver mais. Sem isto, «não cheguei ao cego» é
--                         uma frase e não um dado.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE A TOLERÂNCIA E AS LIMITAÇÕES NÃO SÃO TEXTO LIVRE
-- ─────────────────────────────────────────────────────────────────────────────
-- «Mal tolerado» dito por dez pessoas são dez frases diferentes. Como valor
-- fechado é um dado: conta-se, compara-se, e entra na decisão da sedação seguinte.
--
-- As limitações são uma LISTA de motivos, e não uma frase. Uma frase serve para
-- ler; uma lista serve para contar — e «quantos exames não chegam ao cego por
-- estenose?» é a pergunta que muda a prática.
--
-- O `dispositivo` fica em TEXTO LIVRE: não há catálogo de aparelhos por clínica, e
-- inventá-lo agora obrigaria a decidir a sua forma sem um caso real. Fica escrito
-- o que se usou, e tipifica-se quando houver mais do que um aparelho para gerir.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O `segmento_alcancado` CONVIVE COM O `ate_onde_se_chegou`, E NÃO O SUBSTITUI
-- ─────────────────────────────────────────────────────────────────────────────
-- O `ate_onde_se_chegou` é texto livre, e serve para o que o dicionário não prevê
-- («íleo terminal a 5 cm da válvula»). O `segmento_alcancado` é um CÓDIGO do
-- dicionário, e serve para contar — é ele que responde a «a que profundidade
-- chega este serviço?».
--
-- Ter os dois é deliberado: um obriga a fechar o vocabulário, o outro deixa
-- registar o que a norma não previu. **Tirar o texto livre obrigaria a mentir no
-- código; tirar o código tornaria o alcance incontável.**
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. AS COLUNAS
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'endo_exames'
       and column_name = 'dispositivo'
  ) then
    alter table public.endo_exames add column dispositivo text;
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'endo_exames'
       and column_name = 'segmento_alcancado'
  ) then
    alter table public.endo_exames add column segmento_alcancado text;
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'endo_exames'
       and column_name = 'tolerancia'
  ) then
    alter table public.endo_exames add column tolerancia text;
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'endo_exames'
       and column_name = 'limitacoes'
  ) then
    /* Lista de códigos. Como `complicacoes`, e pela mesma razão: é uma lista curta
       e esparsa, que se conta mas não se agrega por código. */
    alter table public.endo_exames add column limitacoes jsonb not null default '[]'::jsonb;
  end if;

  /* O segmento alcançado tem de ser uma localização DO DICIONÁRIO, quando o
     dicionário existe. Um código inventado tornaria a contagem de alcance uma
     contagem de coisas diferentes. */
  if exists (
    select 1 from information_schema.tables
     where table_schema = 'public' and table_name = 'endo_localizacoes'
  ) and not exists (
    select 1 from pg_constraint where conname = 'endo_exames_segmento_alcancado_fkey'
  ) then
    alter table public.endo_exames
      add constraint endo_exames_segmento_alcancado_fkey
      foreign key (segmento_alcancado) references public.endo_localizacoes(codigo)
      on delete restrict;
  end if;
end $$;

comment on column public.endo_exames.dispositivo is
  'Com que aparelho se fez o exame. Texto livre: nao ha catalogo de aparelhos por clinica.';

comment on column public.endo_exames.segmento_alcancado is
  'Ate onde se chegou, como CODIGO do dicionario. Conta-se, ao contrario do ate_onde_se_chegou (texto livre), que serve para o que a norma nao previu.';

comment on column public.endo_exames.tolerancia is
  'Como o doente tolerou. Valor fechado e nao texto livre: e o que decide a sedacao da proxima vez.';

comment on column public.endo_exames.limitacoes is
  'O que impediu ver mais. Lista de codigos: uma frase serve para ler, uma lista serve para contar.';


-- ---------------------------------------------------------------------------
-- 2. A TOLERÂNCIA, FECHADA
--
-- Três valores, e não cinco. A escala fina não se usa na prática, e uma escala
-- que ninguém usa é uma escala em que cada um escolhe o que quer — que é o mesmo
-- que não haver escala.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'endo_exames_tolerancia_valida') then
    alter table public.endo_exames
      add constraint endo_exames_tolerancia_valida
      check (tolerancia is null
             or tolerancia in ('bem_tolerado', 'moderadamente_tolerado', 'mal_tolerado'));
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_notnull text;
begin
  select string_agg(c, ', ') into v_falta
    from unnest(array['dispositivo', 'segmento_alcancado', 'tolerancia', 'limitacoes']) c
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'endo_exames'
        and column_name = c
   );

  if v_falta is not null then
    raise exception 'Faltam colunas em endo_exames: %', v_falta;
  end if;

  /* As três de texto têm de aceitar nulo: os exames que já existem não as têm, e
     um NOT NULL teria recusado a migração sobre dados reais. (O `limitacoes` tem
     default, e por isso é NOT NULL com valor — que é o correto para uma lista.) */
  select string_agg(column_name, ', ') into v_notnull
    from information_schema.columns
   where table_schema = 'public' and table_name = 'endo_exames'
     and column_name in ('dispositivo', 'segmento_alcancado', 'tolerancia')
     and is_nullable = 'NO';

  if v_notnull is not null then
    raise exception 'Estas colunas ficaram NOT NULL e recusariam os exames que ja existem: %', v_notnull;
  end if;

  /* E a verificação que importa: a tolerância TEM de recusar um valor inventado.
     Uma restrição escrita e não testada é uma restrição que se acredita ter. */
  if not exists (select 1 from pg_constraint where conname = 'endo_exames_tolerancia_valida') then
    raise exception 'A restricao da tolerancia nao foi criada — qualquer texto seria aceite.';
  end if;

  raise notice 'O exame passou a registar o dispositivo, o segmento alcancado, a tolerancia e as limitacoes.';
end $$;


-- ----------------------------------------------------------------------------
-- 0039_equipa_e_medicacao_do_exame.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0039 — QUEM FEZ O EXAME, E O QUE SE DEU
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE ISTO NÃO É UM CAMPO DE TEXTO
-- ─────────────────────────────────────────────────────────────────────────────
-- Num exame com sedação, **quem fez e quem sedou são responsabilidades**, e o que
-- se administrou é um ato clínico com dose e hora. Nada disto cabe num campo de
-- texto livre do exame:
--
--   · A EQUIPA responde a «quem fez este exame?» — que é a pergunta que se faz
--     quando é preciso corrigir alguma coisa, ou saber quantos exames fez cada um.
--     Um exame pode ter endoscopista, anestesista, enfermeiro e ajudante, e os
--     papéis NÃO são todos os mesmos.
--
--   · A MEDICAÇÃO responde a «o que é que se deu e quanto?». É a informação que
--     falta quando o doente reage mal, e a que se procura ao preparar a sedação
--     seguinte. **Uma linha por administração, com dose e hora** — porque um exame
--     pode levar midazolam, depois fentanil, depois mais midazolam, e a sequência
--     é o que interessa.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE A MEDICAÇÃO NÃO É UM CAMPO `jsonb` DO EXAME
-- ─────────────────────────────────────────────────────────────────────────────
-- A tentação era um `jsonb` como as complicações. Não se fez, porque a medicação
-- é uma TABELA DE VERDADE dentro do exame: cresce durante o exame, é escrita por
-- pessoas diferentes (quem seda regista o que dá), e tem de PODER SER CONTADA —
-- «quantos exames levaram midazolam acima de 5 mg?» é uma pergunta de segurança.
--
-- As complicações são esparsas e curtas e não se agregam; a medicação é uma lista
-- que cresce e se agrega. São coisas diferentes, e por isso têm formas diferentes.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- ESTAS TABELAS NÃO TÊM `clinica_id`, E É DE PROPÓSITO
-- ─────────────────────────────────────────────────────────────────────────────
-- Seguem as outras filhas do exame (`endo_lesoes`, `endo_amostras`): filtram pelo
-- EXAME, e a política sobe até ao `clinica_id` dele.
--
-- Uma coluna `clinica_id` aqui seria uma TERCEIRA cópia da mesma verdade — e a que
-- ninguém atualiza. Se o exame mudasse de clínica, a equipa ficava na antiga, e o
-- isolamento entre clínicas passaria a depender de duas colunas concordarem.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. OS PAPÉIS QUE FALTAVAM NO TIPO `perfil`
--
-- Um anestesista e um intensivista não existiam como perfis. Sem eles, não se
-- consegue registar quem sedou — e é essa a pessoa que responde pela sedação.
--
-- `add value if not exists` é seguro dentro de uma transação desde o PostgreSQL
-- 12: o valor não pode é ser USADO na mesma transação, e não é usado aqui — o
-- `endo_equipa.papel` é texto, e não este tipo.
-- ---------------------------------------------------------------------------
do $$ begin
  alter type public.perfil_tipo add value if not exists 'anestesista';
exception when duplicate_object then null; end $$;

do $$ begin
  alter type public.perfil_tipo add value if not exists 'intensivista';
exception when duplicate_object then null; end $$;

do $$ begin
  alter type public.perfil_tipo add value if not exists 'gastrenterologista';
exception when duplicate_object then null; end $$;


-- ---------------------------------------------------------------------------
-- 2. QUEM FEZ O EXAME
--
-- Uma linha por pessoa. O papel é um valor FECHADO: «quem fez o quê» tem de ser
-- contável, e um papel escrito à mão por cada pessoa torna a contagem impossível.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_equipa (
  id              uuid primary key default gen_random_uuid(),
  exame_id        uuid not null references public.endo_exames(id) on delete cascade,
  profissional_id uuid not null references public.profissionais(id) on delete restrict,

  -- O papel no exame. Não é o `perfil` da pessoa: a mesma enfermeira pode ser
  -- ajudante ou observadora em exames diferentes, e o que fica registado é o que
  -- fez NAQUELE exame.
  papel           text not null,

  -- A ordem por que aparecem no relatório. Sem isto, o endoscopista tanto sai
  -- primeiro como último, e duas impressões do mesmo exame não são iguais.
  ordem           smallint not null default 0,

  created_at      timestamptz not null default now(),

  constraint endo_equipa_papel_valido check (papel in (
    'endoscopista',   -- quem faz o exame e responde por ele
    'anestesista',    -- quem seda. Pode ser o mesmo que faz, ou não
    'enfermeiro',     -- apoio direto
    'ajudante',       -- apoio à sala
    'observador'      -- a aprender. Regista-se, e não responde
  )),

  /* A MESMA PESSOA NÃO ENTRA DUAS VEZES no mesmo exame. Sem isto, uma gravação
     repetida punha o endoscopista duas vezes no relatório — e um relatório com o
     mesmo nome duas vezes parece um erro do programa, porque é. */
  constraint endo_equipa_pessoa_unica unique (exame_id, profissional_id),

  constraint endo_equipa_ordem_nao_negativa check (ordem >= 0)
);

create index if not exists endo_equipa_exame on public.endo_equipa (exame_id, ordem);
create index if not exists endo_equipa_profissional on public.endo_equipa (profissional_id);

comment on table public.endo_equipa is
  'Quem fez o exame, e em que papel. Uma linha por pessoa: e a assinatura do registo.';
comment on column public.endo_equipa.papel is
  'O papel NAQUELE exame, que nao e o perfil da pessoa: a mesma enfermeira pode ser ajudante ou observadora em exames diferentes.';


-- ---------------------------------------------------------------------------
-- 3. O QUE SE DEU
--
-- Uma linha por administração, com dose e hora. É a informação que falta quando o
-- doente reage mal, e a que se procura ao preparar a sedação seguinte.
-- ---------------------------------------------------------------------------
create table if not exists public.endo_medicacao (
  id              uuid primary key default gen_random_uuid(),
  exame_id        uuid not null references public.endo_exames(id) on delete cascade,

  -- O que se deu, como texto. Não há catálogo de fármacos nesta base, e inventá-lo
  -- agora obrigaria a decidir a sua forma sem um caso real: os nomes e as
  -- concentrações mudam por serviço e por país.
  farmaco         text not null,

  -- A dose como TEXTO, e não como número: «5 mg», «100 mcg», «2 mg/kg». Uma
  -- unidade fixa obrigaria a converter tudo, e a conversão é onde se perdem doses.
  dose            text,

  via             text,

  -- QUANDO. É a sequência que interessa: midazolam, depois fentanil, depois mais
  -- midazolam. Sem a hora, a lista perde o que a torna útil.
  administrado_em timestamptz not null default now(),

  -- QUEM DEU. Opcional, porque pode não se saber na hora e não vale a pena
  -- inventar — mas quando se sabe, é uma pessoa e não um texto.
  profissional_id uuid references public.profissionais(id) on delete set null,

  notas           text,
  created_at      timestamptz not null default now(),

  constraint endo_medicacao_farmaco_nao_vazio check (length(btrim(farmaco)) > 0),
  constraint endo_medicacao_via_valida check (via is null or via in (
    'iv', 'im', 'sc', 'oral', 'sublingual', 'inalatoria', 'retal', 'nasal', 'topica', 'outra'
  ))
);

create index if not exists endo_medicacao_exame
  on public.endo_medicacao (exame_id, administrado_em);

comment on table public.endo_medicacao is
  'O que se administrou durante o exame. Uma linha por administracao, com dose e hora: a sequencia e o que interessa.';
comment on column public.endo_medicacao.dose is
  'Texto e nao numero: "5 mg", "100 mcg", "2 mg/kg". Uma unidade fixa obrigaria a converter, e a conversao e onde se perdem doses.';


-- ---------------------------------------------------------------------------
-- 4. ACESSO E POLÍTICAS — o MESMO padrão das outras filhas do exame
--
-- Filtram pelo exame, e a política sobe até ao `clinica_id` dele. Uma coluna
-- `clinica_id` aqui seria uma terceira cópia da mesma verdade.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  filhas text[] := array['endo_equipa', 'endo_medicacao'];
begin
  foreach t in array filhas loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated;', t);
    execute format('grant all on public.%I to service_role;', t);

    execute format('drop policy if exists %1$s_do_exame on public.%1$I;', t);
    execute format(
      'create policy %1$s_do_exame on public.%1$I for all to authenticated
         using (exists (select 1 from public.endo_exames e
                         where e.id = %1$I.exame_id
                           and e.clinica_id = clinia.current_clinica_id()))
         with check (exists (select 1 from public.endo_exames e
                              where e.id = %1$I.exame_id
                                and e.clinica_id = clinia.current_clinica_id()));', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 5. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_sem_rls text;
  v_sem_politica text;
begin
  select string_agg(t, ', ') into v_falta
    from unnest(array['endo_equipa', 'endo_medicacao']) t
   where not exists (
     select 1 from information_schema.tables
      where table_schema = 'public' and table_name = t
   );

  if v_falta is not null then
    raise exception 'Faltam tabelas: %', v_falta;
  end if;

  /* As duas TÊM de ter segurança ao nível da linha. Uma tabela clínica sem RLS
     numa base multi-inquilino é uma fuga de dados à espera de acontecer — e é o
     tipo de coisa que não se vê a olhar para o ecrã. */
  select string_agg(t, ', ') into v_sem_rls
    from unnest(array['endo_equipa', 'endo_medicacao']) t
   where not exists (
     select 1 from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = t and c.relrowsecurity
   );

  if v_sem_rls is not null then
    raise exception 'Estas tabelas ficaram SEM seguranca ao nivel da linha: %', v_sem_rls;
  end if;

  /* RLS LIGADO E SEM POLÍTICA É PIOR DO QUE RLS DESLIGADO: a tabela fica
     inacessível, e ninguém percebe porquê. A política tem de existir mesmo. */
  select string_agg(t, ', ') into v_sem_politica
    from unnest(array['endo_equipa', 'endo_medicacao']) t
   where not exists (
     select 1 from pg_policies
      where schemaname = 'public' and tablename = t
   );

  if v_sem_politica is not null then
    raise exception 'Estas tabelas tem RLS mas NAO tem politica — ficariam inacessiveis: %', v_sem_politica;
  end if;

  /* E a unicidade da pessoa no exame tem de existir: é o que impede o mesmo nome
     duas vezes no relatório. */
  if not exists (select 1 from pg_constraint where conname = 'endo_equipa_pessoa_unica') then
    raise exception 'Falta a restricao que impede a mesma pessoa duas vezes no mesmo exame.';
  end if;

  raise notice 'O exame passou a ter equipa e medicacao registadas.';
end $$;


-- ----------------------------------------------------------------------------
-- 0040_episodio_de_endoscopia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0040 — O EPISÓDIO DE ENDOSCOPIA NÃO É O DE REABILITAÇÃO
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O DEFEITO, E PORQUE É QUE ELE É DE CONCEITO E NÃO DE RÓTULO
-- ─────────────────────────────────────────────────────────────────────────────
-- O formulário do episódio pedia duas coisas, e as duas eram de reabilitação:
--
--   · «Queixa principal, nas palavras do utente» — o comentário da coluna di-lo
--     sem rodeios: *«Referência para avaliar ganho funcional real.»*
--   · «O que o utente espera voltar a fazer» — «voltar a jogar golfe», «voltar a
--     vestir-me sozinha».
--
-- **Isto faz todo o sentido numa reabilitação, e nenhum numa endoscopia.** Numa
-- reabilitação o episódio é um PERCURSO: meses de sessões, e a frase do doente no
-- início é a régua com que se mede o ganho no fim.
--
-- Numa endoscopia o episódio é um ATO: faz-se o exame, escreve-se a conclusão, e
-- o episódio fecha. **Não há ganho funcional a medir, e não há «voltar a fazer»
-- nada** — há uma pergunta clínica a que o exame responde.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE NÃO SE APAGAM AS COLUNAS
-- ─────────────────────────────────────────────────────────────────────────────
-- As duas continuam a existir, e ficam para o produto de reabilitação — que é onde
-- fazem sentido, e onde já há episódios gravados com elas. **Apagar colunas com
-- dados clínicos para resolver um formulário mal montado seria trocar um defeito
-- de ecrã por uma perda de dados.**
--
-- O que muda é o formulário: em endoscopia pergunta outra coisa.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. AS COLUNAS DO EPISÓDIO DE ENDOSCOPIA
-- ---------------------------------------------------------------------------
do $$
begin
  /* A URGÊNCIA é a primeira pergunta que se faz a uma endoscopia, e a que decide
     se o exame é para a semana ou para amanhã. É um valor FECHADO: «urgente» dito
     de dez maneiras é uma lista que não se pode ordenar — e ordenar por urgência é
     precisamente o que se quer fazer com ela. */
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'episodios'
       and column_name = 'urgencia'
  ) then
    alter table public.episodios add column urgencia text;
  end if;

  /* O QUE JÁ SE FEZ. Uma endoscopia anterior, uma colonoscopia há três anos, uma
     polipectomia. Muda a decisão: um doente com colonoscopia recente não repete
     por tudo e por nada. */
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'episodios'
       and column_name = 'exames_anteriores'
  ) then
    alter table public.episodios add column exames_anteriores text;
  end if;

  /* ANTECEDENTES COM PESO NA DECISÃO: história familiar de cancro colorretal,
     doença inflamatória intestinal, polipos removidos antes, anticoagulação.
     Não é a lista de problemas (essa vive no processo clínico do utente), é o que
     PESA NESTE EPISÓDIO. */
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'episodios'
       and column_name = 'antecedentes_relevantes'
  ) then
    alter table public.episodios add column antecedentes_relevantes text;
  end if;
end $$;

comment on column public.episodios.urgencia is
  'Urgencia do episodio de endoscopia. Valor fechado: ordenar por urgencia e o que se quer fazer com ela.';

comment on column public.episodios.exames_anteriores is
  'Endoscopias anteriores relevantes. Muda a decisao: uma colonoscopia recente nao se repete por tudo e por nada.';

comment on column public.episodios.antecedentes_relevantes is
  'O que PESA NESTE episodio: historia familiar, doenca inflamatoria, polipos removidos, anticoagulacao. Nao e a lista de problemas do utente.';


-- ---------------------------------------------------------------------------
-- 2. A URGÊNCIA, FECHADA
--
-- Três valores, pela mesma razão da tolerância: uma escala que ninguém usa é uma
-- escala em que cada um escolhe o que quer.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'episodios_urgencia_valida') then
    alter table public.episodios
      add constraint episodios_urgencia_valida
      check (urgencia is null
             or urgencia in ('eletiva', 'prioritaria', 'urgente'));
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. A QUEIXA E A EXPECTATIVA PASSAM A SER CONDICIONAIS AO PRODUTO
--
-- A base de dados não sabe de produtos — e não deve saber. O que ela pode fazer é
-- **não deixar um episódio de endoscopia ficar sem o que a endoscopia exige**: a
-- queixa clínica.
--
-- A verificação é feita pelo gatilho do módulo, e não aqui, para não obrigar a
-- coluna a conhecer o produto. Fica registado no comentário.
-- ---------------------------------------------------------------------------
comment on column public.episodios.queixa_principal is
  'Nas palavras do utente. Referencia para avaliar ganho funcional real — REABILITACAO. Em endoscopia o formulario pergunta urgencia, exames anteriores e antecedentes relevantes, e nao este campo.';

comment on column public.episodios.expectativa_utente is
  'O que o utente espera voltar a fazer — REABILITACAO. Nao se aplica a endoscopia: um exame nao e um percurso, e nao ha ganho funcional a medir.';


-- ---------------------------------------------------------------------------
-- 4. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_notnull text;
begin
  select string_agg(c, ', ') into v_falta
    from unnest(array['urgencia', 'exames_anteriores', 'antecedentes_relevantes']) c
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'episodios' and column_name = c
   );

  if v_falta is not null then
    raise exception 'Faltam colunas em episodios: %', v_falta;
  end if;

  /* As três TÊM de aceitar nulo: os episódios que já existem não as têm — e os de
     reabilitação nunca as terão. Um NOT NULL recusaria a migração sobre dados
     reais, e obrigaria a reabilitação a preencher campos de endoscopia. */
  select string_agg(column_name, ', ') into v_notnull
    from information_schema.columns
   where table_schema = 'public' and table_name = 'episodios'
     and column_name in ('urgencia', 'exames_anteriores', 'antecedentes_relevantes')
     and is_nullable = 'NO';

  if v_notnull is not null then
    raise exception 'Estas colunas ficaram NOT NULL e recusariam os episodios que ja existem: %', v_notnull;
  end if;

  /* E a urgência TEM de recusar um valor inventado. */
  if not exists (select 1 from pg_constraint where conname = 'episodios_urgencia_valida') then
    raise exception 'A restricao da urgencia nao foi criada — qualquer texto seria aceite.';
  end if;

  /* As duas colunas de reabilitação TÊM de continuar a existir: apagá-las seria
     perder os episódios de reabilitação que já as têm gravadas. */
  if exists (
    select 1 from unnest(array['queixa_principal', 'expectativa_utente']) c
     where not exists (
       select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'episodios' and column_name = c
     )
  ) then
    raise exception 'As colunas de reabilitacao desapareceram — os episodios que as usam perderam-se.';
  end if;

  raise notice 'O episodio de endoscopia passou a ter urgencia, exames anteriores e antecedentes.';
end $$;


-- ----------------------------------------------------------------------------
-- 0041_motivos_de_endoscopia_na_base.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0041 — OS MOTIVOS DE ENDOSCOPIA TÊM DE EXISTIR NA BASE
--
-- ─────────────────────────────────────────────────────────────────────────────
-- UM DEFEITO QUE EU TINHA DEIXADO PASSAR, E QUE SÓ APARECEU AO TESTAR
-- ─────────────────────────────────────────────────────────────────────────────
-- Quando fiz a lista de motivos por produto, acrescentei ao `namespace.js` os
-- motivos de gastrenterologia — dispepsia, refluxo, disfagia, rastreio colorretal,
-- etc. **Ficou a parecer que estava feito, porque o ecrã mostrava-os.**
--
-- Mas `episodios.motivo_principal` é do tipo `episodio_motivo`, e esse tipo só tem
-- os valores de REABILITAÇÃO. **A base de dados recusaria gravar «dispepsia».**
--
-- O ecrã mostrava uma lista, o utilizador escolhia, e a gravação falhava com um
-- erro de tipo que não diz nada a ninguém. É o pior género de defeito: a lista certa
-- com o destino errado, e o erro só aparece depois de a pessoa ter feito o trabalho.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORQUE É QUE OS DOIS CONJUNTOS COEXISTEM NO MESMO TIPO
-- ─────────────────────────────────────────────────────────────────────────────
-- Não se fez um tipo por produto. As razões:
--
--   · Os episódios que já existem têm valores de reabilitação, e um tipo novo
--     obrigaria a migrar dados clínicos — para resolver um problema de vocabulário.
--   · «Segunda opinião» e «outro» existem nos dois produtos, e são o mesmo conceito.
--   · A base de dados não sabe de produtos, e não deve saber: quem decide que lista
--     se oferece é o `namespace`, e é lá que a decisão está. **O tipo é o conjunto
--     de tudo o que é DIZÍVEL; a lista do ecrã é o que é OFERECIDO.**
--
-- Confundir as duas coisas — o que é possível e o que é oferecido — é o que dava
-- origem a este defeito. Ficam separadas, e cada uma no seu sítio.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. OS MOTIVOS DE ENDOSCOPIA
--
-- `add value if not exists` é seguro dentro de uma transação desde o PostgreSQL 12:
-- o valor não pode é ser USADO na mesma transação — e nenhum destes é usado aqui.
-- Há um teste que os usa, e corre depois de a migração estar aplicada.
-- ---------------------------------------------------------------------------
do $$
declare
  v text;
  motivos text[] := array[
    'dispepsia',                -- dor epigástrica, má digestão
    'refluxo',                  -- doença de refluxo gastroesofágico
    'disfagia',                 -- dificuldade em engolir
    'hemorragia_digestiva',
    'anemia_ferropenica',       -- a esclarecer
    'diarreia_cronica',
    'dor_abdominal',
    'alteracao_habito_intestinal',
    'perda_de_peso',            -- não intencional
    'rastreio',                 -- rastreio colorretal
    'vigilancia',               -- vigilância de lesão conhecida
    'doenca_inflamatoria',
    'pos_polipectomia',         -- controlo depois de remover pólipos
    'confirmacao_diagnostica'
  ];
begin
  foreach v in array motivos loop
    execute format('alter type public.episodio_motivo add value if not exists %L', v);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 2. VERIFICAÇÃO — a migração não confia em si própria
--
-- A verificação repete a lista, de propósito. Se as duas listas divergirem, a
-- migração falha — e é melhor falhar aqui do que gravar um episódio a menos.
-- ---------------------------------------------------------------------------
do $$
declare
  v_falta text;
  v_existe boolean;
begin
  select string_agg(m, ', ') into v_falta
    from unnest(array[
      'dispepsia', 'refluxo', 'disfagia', 'hemorragia_digestiva',
      'anemia_ferropenica', 'diarreia_cronica', 'dor_abdominal',
      'alteracao_habito_intestinal', 'perda_de_peso', 'rastreio', 'vigilancia',
      'doenca_inflamatoria', 'pos_polipectomia', 'confirmacao_diagnostica'
    ]) m
   where not exists (
     select 1 from pg_enum e
       join pg_type t on t.oid = e.enumtypid
      where t.typname = 'episodio_motivo' and e.enumlabel = m
   );

  if v_falta is not null then
    raise exception 'Estes motivos nao entraram no tipo episodio_motivo: %', v_falta;
  end if;

  /* E os de reabilitação TÊM de continuar lá: há episódios gravados com eles, e um
     tipo que perdesse valores perdia os episódios que os usam. */
  select exists (
    select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
     where t.typname = 'episodio_motivo' and e.enumlabel = 'dor_cronica'
  ) into v_existe;

  if not v_existe then
    raise exception 'O motivo de reabilitacao «dor_cronica» desapareceu do tipo.';
  end if;

  raise notice 'Os motivos de endoscopia passaram a existir na base de dados.';
end $$;


-- ----------------------------------------------------------------------------
-- 0042_o_medico_de_endoscopia_e_clinico.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0042 — O MÉDICO DE ENDOSCOPIA É UM CLÍNICO
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O DEFEITO, ENCONTRADO AO TESTAR E NÃO A LER
-- ─────────────────────────────────────────────────────────────────────────────
-- O `clinia.e_clinico()` decide quem vê o processo clínico. Tem uma lista FIXA de
-- perfis, escrita quando só existia a reabilitação:
--
--     administrador, fisiatra, fisioterapeuta, osteopata,
--     terapeuta_ocupacional, terapeuta_da_fala, psicologo, enfermeiro
--
-- A migração 0039 acrescentou `gastrenterologista`, `anestesista` e `intensivista`
-- ao tipo `perfil_tipo` — e NÃO os acrescentou a esta lista.
--
-- O RESULTADO, medido: um utilizador com o perfil `gastrenterologista` entra na
-- aplicação e **não vê um único doente**. Zero utentes, zero episódios, zero atos.
-- Vê os exames — porque a tabela dos exames não verifica o papel, o que é o
-- defeito seguinte. Mas o processo clínico, que é o que ele precisa para trabalhar,
-- está-lhe fechado.
--
-- **O médico que faz as endoscopias não consegue usar o produto de endoscopia.**
--
-- ─────────────────────────────────────────────────────────────────────────────
-- E O MESMO ERRO, AO CONTRÁRIO, NAS TABELAS DO EXAME
-- ─────────────────────────────────────────────────────────────────────────────
-- As tabelas do exame (lesões, amostras, medicação, equipa) filtram pela CLÍNICA e
-- não pelo PAPEL. Medido: um utilizador de `rececao` lê as lesões — ou seja, o
-- achado de uma colonoscopia, que é um diagnóstico.
--
-- O esquema diz, na migração 0002, que a receção não exerce: «Perfis que não
-- exercem». **A intenção está escrita; a política não a impunha.**
--
-- ─────────────────────────────────────────────────────────────────────────────
-- A CAUSA COMUM, E A LIÇÃO
-- ─────────────────────────────────────────────────────────────────────────────
-- É a MESMA causa de todos os outros defeitos deste produto: **uma lista fixa
-- escrita quando só existia um produto, e um segundo produto que não foi
-- acrescentado a ela.** O menu do MFR numa clínica de endoscopia, os motivos de
-- reabilitação num episódio de gastro, os motivos de gastro ausentes do tipo da
-- base — e agora os papéis clínicos.
--
-- A correção não é acrescentar três nomes e ficar satisfeito: é pôr um TESTE que
-- compara a lista de papéis clínicos com o tipo `perfil_tipo`, para que o próximo
-- perfil que se acrescentar não fique de fora em silêncio.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. QUEM É CLÍNICO, E QUEM É RECEÇÃO OU MELHOR
--
-- Redefinem-se as duas com os papéis de endoscopia. As listas ficam num sítio só,
-- e há um teste que as compara com o tipo — é o que impede a divergência.
-- ---------------------------------------------------------------------------
create or replace function clinia.e_clinico()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil::text in ('administrador',
                        -- reabilitação
                        'fisiatra', 'fisioterapeuta', 'osteopata',
                        'terapeuta_ocupacional', 'terapeuta_da_fala', 'psicologo',
                        -- endoscopia — quem exerce e responde pelo exame
                        'gastrenterologista', 'anestesista', 'intensivista',
                        -- transversal
                        'enfermeiro')
  );
$$;

comment on function clinia.e_clinico() is
  'Quem ve o processo clinico. Inclui os papeis de endoscopia: sem eles o medico que faz as endoscopias nao ve os seus doentes.';

create or replace function clinia.e_rececao_ou_melhor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.perfis p
     where p.id = auth.uid()
       and p.ativo
       and p.perfil::text in ('administrador', 'gestao', 'rececao',
                        'fisiatra', 'fisioterapeuta', 'osteopata',
                        'terapeuta_ocupacional', 'terapeuta_da_fala', 'psicologo',
                        'gastrenterologista', 'anestesista', 'intensivista',
                        'enfermeiro')
  );
$$;


-- ---------------------------------------------------------------------------
-- 2. QUEM PODE PRESCREVER
--
-- O gatilho que espelha o perfil no diretório de profissionais marcava
-- `prescritor` só para fisiatra e administrador. **Um gastrenterologista
-- prescreve** — é um médico. E um anestesista também.
--
-- Sem isto, o médico de endoscopia aparece no diretório mas não pode prescrever,
-- e a receita falha no sítio onde ele está a trabalhar.
-- ---------------------------------------------------------------------------
create or replace function clinia.sync_profissional_de_perfil()
returns trigger
language plpgsql
security definer
set search_path = public, clinia
as $$
begin
  /* Perfis que não exercem: não entram no diretório clínico. */
  if new.perfil::text in ('utente', 'rececao', 'gestao') then
    update public.profissionais
       set ativo = false
     where perfil_id = new.id;
    return new;
  end if;

  insert into public.profissionais as p (
    clinica_id, perfil_id, nome, perfil, especialidade, numero_cedula,
    email, telefone, cor_agenda, interno, prescritor, ativo
  ) values (
    new.clinica_id, new.id, new.nome, new.perfil, new.especialidade, new.numero_cedula,
    new.email, new.telefone, new.cor_agenda, true,
    /* Quem pode prescrever: médicos. A lista é de MÉDICOS, e não de «reabilitação
       mais administrador» — que era o que estava e deixava o gastrenterologista
       de fora. */
    new.perfil::text in ('fisiatra', 'administrador', 'gastrenterologista',
                        'anestesista', 'intensivista'),
    coalesce(new.ativo, true)
  )
  on conflict (perfil_id) where perfil_id is not null do update
     set clinica_id    = excluded.clinica_id,
         nome          = excluded.nome,
         perfil        = excluded.perfil,
         especialidade = excluded.especialidade,
         numero_cedula = excluded.numero_cedula,
         email         = excluded.email,
         telefone      = excluded.telefone,
         cor_agenda    = excluded.cor_agenda,
         prescritor    = excluded.prescritor,
         ativo         = coalesce(new.ativo, true),
         updated_at    = now();
  return new;
end $$;


-- ---------------------------------------------------------------------------
-- 3. AS TABELAS DO EXAME PASSAM A EXIGIR PAPEL CLÍNICO
--
-- O `endo_exames` FICA COMO ESTÁ, e é deliberado: a lista de trabalho mostra quem
-- vem e que exame é, e a receção precisa disso para receber o doente.
--
-- O que a receção NÃO precisa é de ler o que se viu (as lesões), o que se tirou
-- (as amostras), o que se deu (a medicação) e quem lá estava. **Isso é o registo
-- clínico, e o esquema já dizia, na migração 0002, que a receção não exerce.**
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  clinicas text[] := array['endo_lesoes', 'endo_amostras', 'endo_medicacao', 'endo_equipa'];
begin
  foreach t in array clinicas loop
    execute format('drop policy if exists %1$s_do_exame on public.%1$I;', t);
    execute format(
      'create policy %1$s_do_exame on public.%1$I for all to authenticated
         using (clinia.e_clinico()
                and exists (select 1 from public.endo_exames e
                             where e.id = %1$I.exame_id
                               and e.clinica_id = clinia.current_clinica_id()))
         with check (clinia.e_clinico()
                and exists (select 1 from public.endo_exames e
                             where e.id = %1$I.exame_id
                               and e.clinica_id = clinia.current_clinica_id()));', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 4. VERIFICAÇÃO — a migração não confia em si própria
-- ---------------------------------------------------------------------------
do $$
declare
  v_papel text;
  v_falta text;
begin
  /* Os três papéis clínicos de endoscopia TÊM de estar em `e_clinico()`. Lê-se a
     definição da função, e não a lista deste ficheiro — é a única forma de a
     verificação morder. */
  select string_agg(p, ', ') into v_falta
    from unnest(array['gastrenterologista', 'anestesista', 'intensivista']) p
   where not exists (
     select 1 from pg_proc pr
       join pg_namespace n on n.oid = pr.pronamespace
      where n.nspname = 'clinia' and pr.proname = 'e_clinico'
        and pg_get_functiondef(pr.oid) like '%' || p || '%'
   );

  if v_falta is not null then
    raise exception 'Estes papeis clinicos continuam fora de e_clinico(): %', v_falta;
  end if;

  /* E os de reabilitação NÃO podem ter desaparecido: isso fecharia o produto
     antigo para resolver o novo. */
  select string_agg(p, ', ') into v_falta
    from unnest(array['fisiatra', 'fisioterapeuta', 'psicologo', 'enfermeiro']) p
   where not exists (
     select 1 from pg_proc pr
       join pg_namespace n on n.oid = pr.pronamespace
      where n.nspname = 'clinia' and pr.proname = 'e_clinico'
        and pg_get_functiondef(pr.oid) like '%' || p || '%'
   );

  if v_falta is not null then
    raise exception 'Estes papeis de REABILITACAO desapareceram de e_clinico(): %', v_falta;
  end if;

  /* As tabelas de achados TÊM de exigir papel clínico. RLS ligado e política sem
     papel é o que deixava a receção ler as lesões. */
  select string_agg(t, ', ') into v_falta
    from unnest(array['endo_lesoes', 'endo_amostras', 'endo_medicacao', 'endo_equipa']) t
   where not exists (
     select 1 from pg_policies p
      where p.schemaname = 'public' and p.tablename = t
        and p.qual like '%e_clinico%'
   );

  if v_falta is not null then
    raise exception 'Estas tabelas de achados continuam sem exigir papel clinico: %', v_falta;
  end if;

  raise notice 'O medico de endoscopia passou a ser clinico, e a rececao deixou de ler achados.';
end $$;


-- ----------------------------------------------------------------------------
-- 0043_dados_do_exame_com_clinica.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0043 — OS DADOS DO EXAME SABEM DE QUE CLÍNICA SÃO
-- ============================================================================
--
-- O PROBLEMA
-- ============================================================================
--
-- O módulo de endoscopia trouxe 21 tabelas novas sem `clinica_id`. Fui ver o que
-- eram, e a distinção importa:
--
--   · 14 são CATÁLOGOS — `endo_achados` (28 linhas), `endo_localizacoes` (30),
--     `endo_procedimentos` (3), `endo_classificacoes` (12). São o vocabulário
--     clínico, igual para todas as clínicas. **Não devem ter `clinica_id`**, pela
--     mesma razão que o `cid_catalogo` não tem.
--
--   · 6 são DADOS DE UM EXAME — `endo_lesoes`, `endo_amostras`,
--     `endo_exame_localizacoes`, `endo_exame_preparacao`,
--     `endo_exame_intervencoes`, `endo_equipa`. Estes pertencem a um exame, e um
--     exame é de uma clínica.
--
-- ============================================================================
-- PORQUE É QUE ISTO IMPORTA, E NÃO É ARRUMAÇÃO
-- ============================================================================
--
-- As 6 tabelas já têm política de RLS, e as políticas estão CERTAS: filtram
-- através do exame (`endo_exames_por_clinica` usa `clinica_id`). Confirmei.
--
-- Então porque é que se acrescenta a coluna?
--
-- **Porque uma regra indireta não é verificável pelo teste que existe.** O
-- `testar_isolamento.mjs` pergunta a cada tabela de dados se tem `clinica_id` e
-- política. Uma tabela protegida só pelo pai passa despercebida — e no dia em que
-- alguém escrever uma política nova e esquecer o `exists (... endo_exames ...)`,
-- ninguém dá por isso.
--
-- **A opção A põe estas 6 no mesmo padrão que as outras 44**, e aí o teste
-- apanha-as sozinho. A opção B (confiar no pai) funciona hoje e envelhece mal: a
-- proteção depende de um `exists` que ninguém volta a verificar.
--
-- E é barato AGORA: as seis tabelas estão VAZIAS. Acrescentar uma coluna a uma
-- tabela vazia é uma migração de segundos. Fazê-lo depois de haver exames
-- gravados obrigaria a preencher dados e a reescrever políticas com dados a
-- sério — o mesmo erro que o auditor avisou para não se fazer na faturação.
--
-- ============================================================================
-- A COERÊNCIA, QUE É A PARTE QUE SE PODE ESTRAGAR
-- ============================================================================
--
-- Acrescentar `clinica_id` a uma tabela filha cria a possibilidade de **os dois
-- discordarem**: a lesão diz clínica A e o exame dela diz clínica B. Isso nunca
-- aconteceu porque a coluna não existia; passa a ser possível.
--
-- Resolve-se com um gatilho que **copia a clínica do exame** e recusa se alguém
-- tentar outra. Não se confia em quem escreve: impõe-se.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. A COLUNA
-- ---------------------------------------------------------------------------
do $$
declare
  v_tabela text;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    -- Só se a tabela existir: uma instalação sem o módulo de endoscopia não pode
    -- falhar por causa desta migração.
    if exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then
      execute format(
        'alter table public.%I add column if not exists clinica_id uuid references public.clinicas(id) on delete restrict',
        v_tabela);

      execute format(
        'create index if not exists idx_%1$s_clinica on public.%1$I (clinica_id)',
        v_tabela);
    end if;
  end loop;
end $$;

comment on column public.endo_lesoes.clinica_id is
  'A clinica do exame a que a lesao pertence. Redundante com endo_exames.clinica_id DE PROPOSITO: e o que permite a politica de RLS ser direta, e o gatilho impede que os dois discordem.';

-- ---------------------------------------------------------------------------
-- 2. O GATILHO QUE IMPEDE A DIVERGÊNCIA
-- ---------------------------------------------------------------------------
-- Corre em BEFORE INSERT OR UPDATE. Lê a clínica do exame e:
--   · se `clinica_id` vier nulo, preenche-o;
--   · se vier diferente da do exame, recusa.
--
-- Recusar é o lado certo: uma lesão de outra clínica dentro de um exame desta é
-- uma inconsistência, não um caso a acomodar.
create or replace function clinia.herdar_clinica_do_exame()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid;
begin
  if new.exame_id is null then
    return new;
  end if;

  select e.clinica_id into v_clinica
    from public.endo_exames e
   where e.id = new.exame_id;

  if v_clinica is null then
    raise exception 'O exame % nao existe, ou nao tem clinica.', new.exame_id;
  end if;

  if new.clinica_id is null then
    new.clinica_id := v_clinica;
  elsif new.clinica_id <> v_clinica then
    raise exception
      'A clinica do registo (%) nao e a do exame (%). Um registo dentro de um exame tem de ser da mesma clinica.',
      new.clinica_id, v_clinica
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

comment on function clinia.herdar_clinica_do_exame() is
  'Preenche clinica_id a partir do exame e recusa se vier diferente. Sem isto, acrescentar a coluna criava a possibilidade de os dois discordarem — e uma politica que confia na coluna deixava passar a divergencia.';

do $$
declare
  v_tabela text;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    if exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then
      execute format('drop trigger if exists t_%1$s_clinica on public.%1$I;', v_tabela);
      execute format(
        'create trigger t_%1$s_clinica before insert or update on public.%1$I
           for each row execute function clinia.herdar_clinica_do_exame();', v_tabela);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. AS POLÍTICAS
-- ---------------------------------------------------------------------------
-- A política nova é a MESMA das outras 44 tabelas de dados. Substitui a política
-- indireta que olhava para o exame — a verificação passa a ser direta, e o teste
-- do isolamento passa a vê-la.
--
-- Não se perde nada com a substituição: o gatilho garante que a clínica da linha
-- é a do exame, por isso filtrar por `clinica_id` e filtrar pelo exame dão o
-- mesmo resultado. A diferença é que agora se vê.
do $$
declare
  v_tabela text;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    if exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then
      execute format('drop policy if exists %1$s_do_exame on public.%1$I;', v_tabela);
      execute format('drop policy if exists %1$s_por_clinica on public.%1$I;', v_tabela);

      execute format(
        'create policy %1$s_por_clinica on public.%1$I
           for all to authenticated
           using (clinica_id = clinia.current_clinica_id())
           with check (clinica_id = clinia.current_clinica_id());', v_tabela);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. OS DADOS QUE JÁ EXISTEM
-- ---------------------------------------------------------------------------
-- As seis estão vazias nesta instalação, mas uma instalação que já tenha exames
-- gravados precisa que a coluna seja preenchida — senão passariam a existir
-- linhas invisíveis: `clinica_id` nulo não casa com nenhuma política, e o exame
-- ficava com lesões que ninguém vê.
--
-- **Uma migração que torna dados invisíveis é pior do que uma que falha.** Por
-- isso o preenchimento vem antes de qualquer `NOT NULL`, e é verificado.
do $$
declare
  v_tabela text;
  v_n      integer;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then continue; end if;

    execute format($f$
      update public.%1$I f
         set clinica_id = e.clinica_id
        from public.endo_exames e
       where f.exame_id = e.id
         and f.clinica_id is null
    $f$, v_tabela);

    execute format('select count(*) from public.%I where clinica_id is null', v_tabela)
      into v_n;

    if v_n > 0 then
      raise exception
        'Ficaram % linha(s) em % sem clinica. Nao se torna a coluna obrigatoria com dados por classificar — ficariam invisiveis.', v_n, v_tabela;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. A COLUNA PASSA A SER OBRIGATÓRIA
-- ---------------------------------------------------------------------------
-- Só agora. E só nas tabelas que têm `exame_id` — a `endo_equipa` liga-se ao
-- exame pela mesma coluna, por isso entra também.
do $$
declare
  v_tabela text;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then continue; end if;

    begin
      execute format('alter table public.%I alter column clinica_id set not null', v_tabela);
    exception when others then
      raise exception 'Nao consegui tornar clinica_id obrigatorio em %: %', v_tabela, sqlerrm;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. OS PRIVILÉGIOS, E O RLS LIGADO
-- ---------------------------------------------------------------------------
-- A migração 0029 já liga o RLS a tudo o que existe no catálogo. Isto é uma
-- repetição deliberada: se esta migração correr numa instalação onde a 0029 não
-- chegou a estas tabelas, elas ficavam com política e sem RLS ligado — que no
-- PostgreSQL é o mesmo que não ter política nenhuma.
do $$
declare
  v_tabela text;
begin
  foreach v_tabela in array array[
    'endo_lesoes', 'endo_amostras', 'endo_exame_localizacoes',
    'endo_exame_preparacao', 'endo_exame_intervencoes', 'endo_equipa'
  ]
  loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_tabela and c.relkind = 'r'
    ) then continue; end if;

    execute format('alter table public.%I enable row level security', v_tabela);
    execute format('grant select, insert, update, delete on public.%I to authenticated', v_tabela);
    execute format('grant all on public.%I to service_role', v_tabela);
  end loop;
end $$;

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================
--   1. as 6 tabelas têm clinica_id e política direta:
--
--        select c.relname, (select count(*) from pg_policy p where p.polrelid=c.oid)
--          from pg_class c join pg_namespace n on n.oid=c.relnamespace
--         where n.nspname='public' and c.relname in ('endo_lesoes','endo_amostras',
--           'endo_exame_localizacoes','endo_exame_preparacao',
--           'endo_exame_intervencoes','endo_equipa');
--
--   2. uma lesão herda a clínica do exame:
--
--        insert into public.endo_lesoes (exame_id, ...) values (<exame>, ...);
--        select clinica_id from public.endo_lesoes where id = <lesao>;
--        -- tem de ser igual a (select clinica_id from public.endo_exames where id = <exame>)
--
--   3. e recusa uma clínica diferente:
--
--        insert into public.endo_lesoes (exame_id, clinica_id, ...)
--        values (<exame>, '<outra-clinica>', ...);
--        -- tem de recusar
--
--   4. e o teste do isolamento já as vê:
--
--        node tools/testar_isolamento.mjs
-- ============================================================================


-- ============================================================================
-- PARTE 2 — CATÁLOGOS CLÍNICOS (CIF, CID, escalas, anatomia)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0001_anatomia_e_medicoes.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0001 — Anatomia de referência e tipos de medição
--
-- Porquê semear isto em vez de deixar texto livre: o vetor MOVIMENTO é o meio
-- de diagnóstico (entrada #003: "a avaliação faz-se sempre pelo movimento").
-- Se cada profissional escrever "flexão ombro D" à sua maneira, não há série
-- temporal, não há gráfico e não há comparação entre utentes. A taxonomia é o
-- que transforma observação em dado.
--
-- ADM de referência: valores da literatura clínica (AAOS / AMA Guides),
-- usados como norma de comparação. São referência, não limite.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Regiões anatómicas
-- ---------------------------------------------------------------------------
insert into public.regioes_anatomicas (codigo, nome, regiao_pai, lateralidade, ordem) values
  ('coluna',        'Coluna vertebral',            null,        'central', 10),
  ('coluna_cervical','Coluna cervical',            'coluna',    'central', 11),
  ('coluna_toracica','Coluna torácica',            'coluna',    'central', 12),
  ('coluna_lombar', 'Coluna lombar',               'coluna',    'central', 13),
  ('sacroiliaca',   'Articulações sacroilíacas',   'coluna',    'central', 14),

  ('membro_sup_d',  'Membro superior direito',     null,        'd',       20),
  ('ombro_d',       'Ombro direito',               'membro_sup_d','d',     21),
  ('cotovelo_d',    'Cotovelo direito',            'membro_sup_d','d',     22),
  ('punho_mao_d',   'Punho e mão direitos',        'membro_sup_d','d',     23),

  ('membro_sup_e',  'Membro superior esquerdo',    null,        'e',       30),
  ('ombro_e',       'Ombro esquerdo',              'membro_sup_e','e',     31),
  ('cotovelo_e',    'Cotovelo esquerdo',           'membro_sup_e','e',     32),
  ('punho_mao_e',   'Punho e mão esquerdos',       'membro_sup_e','e',     33),

  ('membro_inf_d',  'Membro inferior direito',     null,        'd',       40),
  ('anca_d',        'Anca direita',                'membro_inf_d','d',     41),
  ('joelho_d',      'Joelho direito',              'membro_inf_d','d',     42),
  ('tornozelo_pe_d','Tornozelo e pé direitos',     'membro_inf_d','d',     43),

  ('membro_inf_e',  'Membro inferior esquerdo',    null,        'e',       50),
  ('anca_e',        'Anca esquerda',               'membro_inf_e','e',     51),
  ('joelho_e',      'Joelho esquerdo',             'membro_inf_e','e',     52),
  ('tornozelo_pe_e','Tornozelo e pé esquerdos',    'membro_inf_e','e',     53),

  ('cranio_mandibula','Crânio e mandíbula',        null,        'central', 60),
  ('torax',         'Caixa torácica',              null,        'central', 61),
  ('bacia',         'Bacia',                       null,        'central', 62),
  ('global',        'Global / corpo inteiro',      null,        'central', 99)
on conflict (codigo) do update
  set nome = excluded.nome,
      regiao_pai = excluded.regiao_pai,
      lateralidade = excluded.lateralidade,
      ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 2. Articulações — movimentos e ADM de referência
--    `adm_normal` alimenta diretamente o denominador da % de recuperação.
-- ---------------------------------------------------------------------------
insert into public.articulacoes (codigo, regiao_codigo, nome, movimentos, adm_normal, ordem) values
  ('coluna_cervical_art', 'coluna_cervical', 'Coluna cervical',
   array['flexao','extensao','rotacao_d','rotacao_e','inclinacao_d','inclinacao_e','retracao','protracao'],
   '{"flexao":45,"extensao":45,"rotacao_d":80,"rotacao_e":80,"inclinacao_d":45,"inclinacao_e":45,"retracao":30,"protracao":15}', 110),

  ('coluna_toracica_art', 'coluna_toracica', 'Coluna torácica',
   array['flexao','extensao','rotacao_d','rotacao_e','inclinacao_d','inclinacao_e'],
   '{"flexao":45,"extensao":25,"rotacao_d":35,"rotacao_e":35,"inclinacao_d":25,"inclinacao_e":25}', 120),

  ('coluna_lombar_art', 'coluna_lombar', 'Coluna lombar',
   array['flexao','extensao','rotacao_d','rotacao_e','inclinacao_d','inclinacao_e'],
   '{"flexao":60,"extensao":25,"rotacao_d":15,"rotacao_e":15,"inclinacao_d":20,"inclinacao_e":20}', 130),

  ('glenoumeral_d', 'ombro_d', 'Ombro direito (glenoumeral)',
   array['flexao','extensao','abducao','aducao','rotacao_interna','rotacao_externa','abducao_horizontal','adução_horizontal'],
   '{"flexao":180,"extensao":60,"abducao":180,"aducao":45,"rotacao_interna":70,"rotacao_externa":90,"abducao_horizontal":90}', 210),
  ('glenoumeral_e', 'ombro_e', 'Ombro esquerdo (glenoumeral)',
   array['flexao','extensao','abducao','aducao','rotacao_interna','rotacao_externa','abducao_horizontal'],
   '{"flexao":180,"extensao":60,"abducao":180,"aducao":45,"rotacao_interna":70,"rotacao_externa":90,"abducao_horizontal":90}', 211),

  ('cotovelo_d', 'cotovelo_d', 'Cotovelo direito',
   array['flexao','extensao','pronacao','supinacao'],
   '{"flexao":150,"extensao":0,"pronacao":80,"supinacao":85}', 220),
  ('cotovelo_e', 'cotovelo_e', 'Cotovelo esquerdo',
   array['flexao','extensao','pronacao','supinacao'],
   '{"flexao":150,"extensao":0,"pronacao":80,"supinacao":85}', 221),

  ('punho_d', 'punho_mao_d', 'Punho direito',
   array['flexao','extensao','desvio_radial','desvio_ulnar'],
   '{"flexao":80,"extensao":70,"desvio_radial":20,"desvio_ulnar":30}', 230),
  ('punho_e', 'punho_mao_e', 'Punho esquerdo',
   array['flexao','extensao','desvio_radial','desvio_ulnar'],
   '{"flexao":80,"extensao":70,"desvio_radial":20,"desvio_ulnar":30}', 231),

  ('anca_d', 'anca_d', 'Anca direita',
   array['flexao','extensao','abducao','aducao','rotacao_interna','rotacao_externa'],
   '{"flexao":120,"extensao":30,"abducao":45,"aducao":30,"rotacao_interna":45,"rotacao_externa":45}', 310),
  ('anca_e', 'anca_e', 'Anca esquerda',
   array['flexao','extensao','abducao','aducao','rotacao_interna','rotacao_externa'],
   '{"flexao":120,"extensao":30,"abducao":45,"aducao":30,"rotacao_interna":45,"rotacao_externa":45}', 311),

  ('joelho_d', 'joelho_d', 'Joelho direito',
   array['flexao','extensao'],
   '{"flexao":135,"extensao":0}', 320),
  ('joelho_e', 'joelho_e', 'Joelho esquerdo',
   array['flexao','extensao'],
   '{"flexao":135,"extensao":0}', 321),

  ('tornozelo_d', 'tornozelo_pe_d', 'Tornozelo direito',
   array['dorsiflexao','flexao_plantar','inversao','eversao'],
   '{"dorsiflexao":20,"flexao_plantar":50,"inversao":35,"eversao":15}', 330),
  ('tornozelo_e', 'tornozelo_pe_e', 'Tornozelo esquerdo',
   array['dorsiflexao','flexao_plantar','inversao','eversao'],
   '{"dorsiflexao":20,"flexao_plantar":50,"inversao":35,"eversao":15}', 331),

  ('atm', 'cranio_mandibula', 'Articulação temporomandibular',
   array['abertura','desvio_d','desvio_e','protrusao'],
   '{"abertura":50,"desvio_d":10,"desvio_e":10,"protrusao":8}', 410),

  ('sacroiliaca_d', 'sacroiliaca', 'Sacroilíaca direita', array['nutacao','contranutacao'], '{}', 140),
  ('sacroiliaca_e', 'sacroiliaca', 'Sacroilíaca esquerda', array['nutacao','contranutacao'], '{}', 141)
on conflict (codigo) do update
  set nome = excluded.nome,
      regiao_codigo = excluded.regiao_codigo,
      movimentos = excluded.movimentos,
      adm_normal = excluded.adm_normal,
      ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 3. Tipos de medição
--    `melhor_direcao` é o campo que impede o gráfico de mentir: subir ADM é
--    melhoria, subir EVA é agravamento. Sem isto, a linha sobe sempre.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
values
  -- Dor
  (null, 'eva', 'EVA — intensidade da dor', 'dor', 'pontos', 0, 'menor_melhor',
   0, 10, false, null, null, 10),
  (null, 'nprs', 'Escala numérica da dor (NPRS)', 'dor', 'pontos', 0, 'menor_melhor',
   0, 10, false, null, null, 11),
  (null, 'dor_pior_24h', 'Dor no pior momento (24h)', 'dor', 'pontos', 0, 'menor_melhor',
   0, 10, false, null, null, 12),
  (null, 'dor_funcional', 'Dor durante atividade funcional', 'dor', 'pontos', 0, 'menor_melhor',
   0, 10, false, null, null, 13),

  -- Amplitude de movimento (ADM) — uma entrada por articulação principal
  (null, 'adm_ombro_flexao', 'ADM flexão do ombro', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 180, true, 'glenoumeral_d', 'flexao', 100),
  (null, 'adm_ombro_abducao', 'ADM abdução do ombro', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 180, true, 'glenoumeral_d', 'abducao', 101),
  (null, 'adm_ombro_rot_ext', 'ADM rotação externa do ombro', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 90, true, 'glenoumeral_d', 'rotacao_externa', 102),
  (null, 'adm_ombro_rot_int', 'ADM rotação interna do ombro', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 70, true, 'glenoumeral_d', 'rotacao_interna', 103),
  (null, 'adm_cotovelo_flexao', 'ADM flexão do cotovelo', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 150, true, 'cotovelo_d', 'flexao', 110),
  (null, 'adm_cervical_rot', 'ADM rotação cervical', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 80, true, 'coluna_cervical_art', 'rotacao_d', 120),
  (null, 'adm_cervical_flexao', 'ADM flexão cervical', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 45, false, 'coluna_cervical_art', 'flexao', 121),
  (null, 'adm_lombar_flexao', 'ADM flexão lombar (Schober modificado)', 'amplitude', 'cm', 1, 'maior_melhor',
   0, 10, false, 'coluna_lombar_art', 'flexao', 130),
  (null, 'adm_anca_flexao', 'ADM flexão da anca', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 120, true, 'anca_d', 'flexao', 140),
  (null, 'adm_joelho_flexao', 'ADM flexão do joelho', 'amplitude', 'graus', 0, 'maior_melhor',
   0, 135, true, 'joelho_d', 'flexao', 150),
  (null, 'adm_tornozelo_dorsiflexao', 'ADM dorsiflexão do tornozelo (teste parede)', 'amplitude', 'cm', 1, 'maior_melhor',
   0, 15, true, 'tornozelo_d', 'dorsiflexao', 160),
  (null, 'distancia_dedo_chao', 'Distância dedos-chão', 'amplitude', 'cm', 1, 'menor_melhor',
   0, 60, false, 'coluna_lombar_art', 'flexao', 170),

  -- Força
  (null, 'forca_oxford', 'Força muscular (Oxford 0-5)', 'forca', 'pontos', 0, 'maior_melhor',
   0, 5, true, null, null, 200),
  (null, 'dinamometria_mao', 'Força de preensão manual (dinamómetro)', 'forca', 'kg', 1, 'maior_melhor',
   0, 80, true, null, null, 201),
  (null, 'dinamometria_quadricipite', 'Força do quadricípite (dinamómetro)', 'forca', 'kg', 1, 'maior_melhor',
   0, 60, true, null, null, 202),

  -- Função e performance
  (null, 'barthel', 'Índice de Barthel', 'funcao', 'pontos', 0, 'maior_melhor',
   0, 100, false, null, null, 300),
  (null, 'tug', 'Timed Up and Go', 'performance', 'segundos', 1, 'menor_melhor',
   0, 60, false, null, null, 310),
  (null, 'velocidade_marcha', 'Velocidade de marcha (10 m)', 'performance', 'm/s', 2, 'maior_melhor',
   0, 2.5, false, null, null, 311),
  (null, 'teste_6min', 'Teste de marcha de 6 minutos', 'performance', 'metros', 0, 'maior_melhor',
   0, 800, false, null, null, 312),
  (null, 'sts30', 'Sentar-levantar 30 segundos', 'performance', 'repeticoes', 0, 'maior_melhor',
   0, 40, false, null, null, 313),
  (null, 'sls', 'Equilíbrio unipodal (Single Leg Stance)', 'performance', 'segundos', 1, 'maior_melhor',
   0, 60, true, null, null, 314),
  (null, 'prancha', 'Prancha isométrica (hold)', 'performance', 'segundos', 1, 'maior_melhor',
   0, 300, false, null, null, 315),
  (null, 'hand_grip_ratio', 'Rácio de força entre lados', 'performance', 'percentagem', 0, 'neutro',
   null, null, false, null, null, 316),

  -- Antropometria e edema
  (null, 'perimetro_articular', 'Perímetro articular (edema)', 'antropometria', 'cm', 1, 'menor_melhor',
   0, 100, true, null, null, 400),
  (null, 'perimetro_abdominal', 'Perímetro abdominal', 'antropometria', 'cm', 1, 'menor_melhor',
   0, 200, false, null, null, 401),

  -- Adesão e autocuidado (a adesão é determinante do resultado)
  (null, 'adesao_hep', 'Adesão ao programa de casa', 'funcao', 'pontos', 0, 'maior_melhor',
   0, 10, false, null, null, 500),
  (null, 'adesao_tratamento', 'Adesão ao tratamento', 'funcao', 'pontos', 0, 'maior_melhor',
   0, 10, false, null, null, 501)
on conflict do nothing;


-- ----------------------------------------------------------------------------
-- 0002_escalas.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0002 — Escalas e instrumentos de avaliação
--
-- Princípio de baixa fricção aplicado aqui: o clínico responde, o sistema
-- calcula. Uma escala com opções definidas e pesos conhecidos elimina a soma
-- à mão e o erro de aritmética que contamina o histórico.
--
-- Todas as escalas são globais (clinica_id null): qualquer clínica as usa. Uma
-- clínica pode criar as suas, que ficam com o seu clinica_id e não se misturam.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. EVA — intensidade da dor
--    A escala mais usada em MFR e a mais mal utilizada: regista intensidade e
--    esquece o mecanismo. Aqui é deliberadamente mínima (é a intensidade) e
--    aponta para o vetor DOR, onde a origem é caracterizada a sério.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica)
values
  (null, 'eva', 'Escala Visual Analógica da Dor', 'EVA', '1.0', 'dor', 'valor_unico',
   0, 10,
   '[{"max":0,"rotulo":"sem dor","gravidade":"ausente"},
     {"max":3,"rotulo":"dor ligeira","gravidade":"leve"},
     {"max":6,"rotulo":"dor moderada","gravidade":"moderada"},
     {"max":10,"rotulo":"dor intensa","gravidade":"grave"}]'::jsonb,
   true, array['adulto','senior','pediatrico'], 'mfr',
   'Intensidade da dor de 0 (sem dor) a 10 (pior dor imaginável). Caracterizar sempre com a origem em mfr_avaliacao_dor.',
   'Huskisson 1974; Jensen & Karoly 2001')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, ajuda, tipo_resposta, min_valor, max_valor, unidade, obrigatorio, vetor)
select e.id, 1, 'valor', 'Intensidade da dor neste momento (0-10)',
       '0 = sem dor, 10 = a pior dor imaginável. Registe também a origem da dor no vetor DOR.',
       'escala_visual', 0, 10, 'pontos', true, 'dor'
  from public.escalas e
 where e.codigo = 'eva' and e.clinica_id is null
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. NPRS — escala numérica (alternativa verbal à EVA)
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica)
values
  (null, 'nprs', 'Escala Numérica de Avaliação da Dor', 'NPRS', '1.0', 'dor', 'valor_unico',
   0, 10,
   '[{"max":0,"rotulo":"sem dor","gravidade":"ausente"},
     {"max":3,"rotulo":"dor ligeira","gravidade":"leve"},
     {"max":6,"rotulo":"dor moderada","gravidade":"moderada"},
     {"max":10,"rotulo":"dor intensa","gravidade":"grave"}]'::jsonb,
   true, array['adulto','senior'], 'mfr',
   'Dor de 0 a 10 relatada verbalmente. Útil quando o utente não consegue usar a escala visual.',
   'Farrar et al. 2001')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, tipo_resposta, min_valor, max_valor, unidade, obrigatorio, vetor)
select e.id, 1, 'valor', 'Intensidade da dor (0-10)', 'numero', 0, 10, 'pontos', true, 'dor'
  from public.escalas e
 where e.codigo = 'nprs' and e.clinica_id is null
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 3. Índice de Barthel — autonomia nas atividades de vida diária
--    Este é o instrumento que dá corpo ao vetor FUNÇÃO em utentes com perda de
--    autonomia. Total 100 = independente.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica)
values
  (null, 'barthel', 'Índice de Barthel', 'Barthel', '1.0', 'funcao', 'soma',
   0, 100,
   '[{"max":20,"rotulo":"dependência total","gravidade":"total"},
     {"max":60,"rotulo":"dependência grave","gravidade":"grave"},
     {"max":90,"rotulo":"dependência moderada","gravidade":"moderada"},
     {"max":99,"rotulo":"dependência ligeira","gravidade":"leve"},
     {"max":100,"rotulo":"independente","gravidade":"ausente"}]'::jsonb,
   false, array['adulto','senior'], 'mfr',
   'Avalia a autonomia em 10 atividades de vida diária. É a referência para medir ganho funcional em reabilitação.',
   'Mahoney & Barthel 1965')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, tipo_resposta, opcoes, min_valor, max_valor, obrigatorio, vetor)
select e.id, v.ordem, v.codigo, v.texto, 'opcoes', v.opcoes::jsonb, 0, v.maximo, true, 'funcao'
  from public.escalas e
  cross join (values
    (1,  'alimentacao', 'Alimentação',
     '[{"valor":10,"rotulo":"Independente — come sozinho"},
       {"valor":5,"rotulo":"Precisa de ajuda em algumas tarefas (cortar, passar manteiga)"},
       {"valor":0,"rotulo":"Dependente — necessita de ser alimentado"}]', 10),
    (2,  'banho', 'Banho',
     '[{"valor":5,"rotulo":"Independente — toma banho sozinho"},
       {"valor":0,"rotulo":"Dependente — precisa de ajuda"}]', 5),
    (3,  'higiene_pessoal', 'Higiene pessoal (lavar rosto, mãos, dentes, barbear)',
     '[{"valor":5,"rotulo":"Independente"},
       {"valor":0,"rotulo":"Dependente — precisa de ajuda"}]', 5),
    (4,  'vestir', 'Vestir e despir',
     '[{"valor":10,"rotulo":"Independente — inclui botões e atacadores"},
       {"valor":5,"rotulo":"Precisa de ajuda, mas faz metade sozinho"},
       {"valor":0,"rotulo":"Dependente"}]', 10),
    (5,  'intestinos', 'Controlo intestinal (defecação)',
     '[{"valor":10,"rotulo":"Continente — controla totalmente"},
       {"valor":5,"rotulo":"Episódio ocasional de incontinência ou precisa de ajuda com supositório"},
       {"valor":0,"rotulo":"Incontinente"}]', 10),
    (6,  'bexiga', 'Controlo vesical (micção)',
     '[{"valor":10,"rotulo":"Continente — controla totalmente"},
       {"valor":5,"rotulo":"Episódio ocasional de incontinência ou precisa de ajuda com sonda"},
       {"valor":0,"rotulo":"Incontinente"}]', 10),
    (7,  'sanita', 'Utilização da sanita',
     '[{"valor":10,"rotulo":"Independente — usa, limpa-se e veste-se sozinho"},
       {"valor":5,"rotulo":"Precisa de alguma ajuda, mas faz parte sozinho"},
       {"valor":0,"rotulo":"Dependente"}]', 10),
    (8,  'transferencias', 'Transferências (cama para cadeira e vice-versa)',
     '[{"valor":15,"rotulo":"Independente"},
       {"valor":10,"rotulo":"Mínima ajuda ou supervisão"},
       {"valor":5,"rotulo":"Ajuda considerável — consegue sentar-se"},
       {"valor":0,"rotulo":"Dependente — sem equilíbrio sentado"}]', 15),
    (9,  'mobilidade', 'Mobilidade (andar ou usar cadeira de rodas)',
     '[{"valor":15,"rotulo":"Independente — anda 45 m ou usa cadeira de rodas sozinho"},
       {"valor":10,"rotulo":"Ajuda de uma pessoa para andar 45 m"},
       {"valor":5,"rotulo":"Independente em cadeira de rodas (inclui esquinas)"},
       {"valor":0,"rotulo":"Imóvel — dependente"}]', 15),
    (10, 'escadas', 'Subir e descer escadas',
     '[{"valor":10,"rotulo":"Independente"},
       {"valor":5,"rotulo":"Precisa de ajuda ou supervisão"},
       {"valor":0,"rotulo":"Dependente"}]', 10)
  ) as v(ordem, codigo, texto, opcoes, maximo)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 4. Confirmação das seeds (verificação, não só inserção)
--    Um seed que falha em silêncio é pior do que não correr.
-- ---------------------------------------------------------------------------
do $$
declare
  v_regioes   integer;
  v_art       integer;
  v_medicoes  integer;
  v_escalas   integer;
  v_itens     integer;
  v_problemas text[] := '{}';
begin
  select count(*) into v_regioes  from public.regioes_anatomicas;
  select count(*) into v_art      from public.articulacoes;
  select count(*) into v_medicoes from public.tipos_medicao where clinica_id is null;
  select count(*) into v_escalas  from public.escalas where clinica_id is null;
  select count(*) into v_itens    from public.escala_itens;

  raise notice 'Seeds — regiões: %, articulações: %, tipos de medição: %, escalas: %, itens: %',
    v_regioes, v_art, v_medicoes, v_escalas, v_itens;

  if v_regioes = 0  then v_problemas := v_problemas || 'regioes_anatomicas vazia'; end if;
  if v_art = 0      then v_problemas := v_problemas || 'articulacoes vazia'; end if;
  if v_medicoes = 0 then v_problemas := v_problemas || 'tipos_medicao vazia'; end if;
  if v_escalas = 0  then v_problemas := v_problemas || 'escalas vazia'; end if;

  -- A Barthel tem de somar exatamente 100 no máximo das opções.
  if (select sum(max_valor) from public.escala_itens i
        join public.escalas e on e.id = i.escala_id
       where e.codigo = 'barthel') <> 100 then
    v_problemas := v_problemas || 'Barthel não soma 100';
  end if;

  if array_length(v_problemas, 1) > 0 then
    raise exception 'Seeds com problemas: %', array_to_string(v_problemas, '; ');
  end if;

  raise notice 'Seeds de catálogo clínico verificadas com sucesso.';
end $$;


-- ----------------------------------------------------------------------------
-- 0003_cif_cid.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0003 — CIF e CID (subconjunto clínico de MFR)
--
-- NOTA DE ÂMBITO, deliberada: isto NÃO é a CIF completa nem o CID-10 completo.
-- É um subconjunto curado das categorias que aparecem no dia a dia de MFR. O
-- valor de arrancar com ~150 códigos certos em vez de 14 000 inúteis é enorme
-- em baixa fricção: o clínico escolhe numa lista curta, não numa enciclopédia.
--
-- A importação dos catálogos oficiais completos (CIF/OMS e CID-10/ICD-11) é um
-- passo separado e mecanizável — ver docs/arquitetura.md. As tabelas já estão
-- preparadas para receber a totalidade (hierarquia em codigo_pai, e o campo
-- cid_catalogo.sistema permite ICD-11 sem migração).
--
-- ORDEM DAS INSERÇÕES: a FK auto-referenciada de cif_catalogo(codigo_pai) é
-- verificada linha a linha, por isso cada nível tem de ser inserido antes dos
-- seus filhos. Este ficheiro insere por nível (1, 2, 3, 4) e não por capítulo,
-- que seria a ordem natural de leitura mas inválida para a base de dados.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. CIF — nível 1 (grandes componentes)
-- ---------------------------------------------------------------------------
insert into public.cif_catalogo (codigo, componente, capitulo, descricao, descricao_curta, codigo_pai, nivel, usa_qualificador) values
  ('b1', 'b', 'b1', 'Funções mentais', 'Funções mentais', null, 1, false),
  ('b2', 'b', 'b2', 'Funções sensoriais e dor', 'Sensoriais e dor', null, 1, false),
  ('b4', 'b', 'b4', 'Funções dos sistemas cardiovascular, hematológico, imunológico e respiratório', 'Cardiorrespiratório', null, 1, false),
  ('b5', 'b', 'b5', 'Funções dos sistemas digestivo, metabólico e endócrino', 'Digestivo e metabólico', null, 1, false),
  ('b6', 'b', 'b6', 'Funções geniturinárias e reprodutivas', 'Geniturinário', null, 1, false),
  ('b7', 'b', 'b7', 'Funções neuromusculoesqueléticas e relacionadas com o movimento', 'Movimento', null, 1, false),
  ('s7', 's', 's7', 'Estruturas relacionadas com o movimento', 'Estruturas do movimento', null, 1, false),
  ('d4', 'd', 'd4', 'Mobilidade', 'Mobilidade', null, 1, false),
  ('d5', 'd', 'd5', 'Autocuidado', 'Autocuidado', null, 1, false),
  ('d6', 'd', 'd6', 'Vida doméstica', 'Vida doméstica', null, 1, false),
  ('d8', 'd', 'd8', 'Áreas principais da vida', 'Vida principal', null, 1, false),
  ('d9', 'd', 'd9', 'Vida comunitária, social e cívica', 'Vida social', null, 1, false),
  ('e1', 'e', 'e1', 'Produtos e tecnologia', 'Produtos e tecnologia', null, 1, false),
  ('e3', 'e', 'e3', 'Apoio e relacionamentos', 'Apoio social', null, 1, false),
  ('e4', 'e', 'e4', 'Atitudes', 'Atitudes', null, 1, false),
  ('e5', 'e', 'e5', 'Serviços, sistemas e políticas', 'Serviços e políticas', null, 1, false)
on conflict (codigo) do update
  set descricao = excluded.descricao, descricao_curta = excluded.descricao_curta,
      componente = excluded.componente, capitulo = excluded.capitulo,
      codigo_pai = excluded.codigo_pai, nivel = excluded.nivel,
      usa_qualificador = excluded.usa_qualificador;

-- ---------------------------------------------------------------------------
-- 2. CIF — nível 2
-- ---------------------------------------------------------------------------
insert into public.cif_catalogo (codigo, componente, capitulo, descricao, descricao_curta, codigo_pai, nivel, usa_qualificador) values
  -- b1 funções mentais
  ('b130', 'b', 'b1', 'Funções da energia e dos impulsos', 'Energia e impulsos', 'b1', 2, true),
  ('b134', 'b', 'b1', 'Funções do sono', 'Sono', 'b1', 2, true),
  ('b152', 'b', 'b1', 'Funções emocionais', 'Emoções', 'b1', 2, true),
  ('b180', 'b', 'b1', 'Funções da experiência pessoal e do tempo', 'Experiência pessoal', 'b1', 2, true),
  -- b2 sensoriais e dor
  ('b235', 'b', 'b2', 'Funções vestibulares', 'Equilíbrio vestibular', 'b2', 2, true),
  ('b260', 'b', 'b2', 'Função propriocectiva', 'Propriocepção', 'b2', 2, true),
  ('b265', 'b', 'b2', 'Função tátil', 'Tato', 'b2', 2, true),
  ('b270', 'b', 'b2', 'Funções sensoriais relacionadas com a temperatura e outros estímulos', 'Sensibilidade térmica', 'b2', 2, true),
  ('b280', 'b', 'b2', 'Sensação de dor', 'Dor', 'b2', 2, true),
  -- b4 cardiorrespiratório
  ('b410', 'b', 'b4', 'Funções cardíacas', 'Função cardíaca', 'b4', 2, true),
  ('b440', 'b', 'b4', 'Funções respiratórias', 'Respiração', 'b4', 2, true),
  ('b455', 'b', 'b4', 'Funções de tolerância ao exercício', 'Tolerância ao exercício', 'b4', 2, true),
  -- b5 e b6
  ('b525', 'b', 'b5', 'Funções de defecação', 'Defecação', 'b5', 2, true),
  ('b620', 'b', 'b6', 'Funções urinárias', 'Função urinária', 'b6', 2, true),
  -- b7 movimento (o núcleo de MFR)
  ('b710', 'b', 'b7', 'Funções da mobilidade de uma articulação', 'Mobilidade articular', 'b7', 2, true),
  ('b715', 'b', 'b7', 'Funções da estabilidade de uma articulação', 'Estabilidade articular', 'b7', 2, true),
  ('b730', 'b', 'b7', 'Funções da força muscular', 'Força muscular', 'b7', 2, true),
  ('b735', 'b', 'b7', 'Funções do tónus muscular', 'Tónus muscular', 'b7', 2, true),
  ('b740', 'b', 'b7', 'Funções da resistência muscular', 'Resistência muscular', 'b7', 2, true),
  ('b750', 'b', 'b7', 'Funções dos reflexos motores', 'Reflexos motores', 'b7', 2, true),
  ('b755', 'b', 'b7', 'Funções das reações motoras involuntárias', 'Reações posturais', 'b7', 2, true),
  ('b760', 'b', 'b7', 'Funções do controlo dos movimentos voluntários', 'Controlo do movimento', 'b7', 2, true),
  ('b765', 'b', 'b7', 'Funções dos movimentos involuntários', 'Movimentos involuntários', 'b7', 2, true),
  ('b770', 'b', 'b7', 'Funções do padrão de marcha', 'Padrão de marcha', 'b7', 2, true),
  ('b780', 'b', 'b7', 'Sensações relacionadas com os músculos e funções do movimento', 'Sensações musculares', 'b7', 2, true),
  -- s7 estruturas
  ('s710', 's', 's7', 'Estrutura da região da cabeça e do pescoço', 'Cabeça e pescoço', 's7', 2, true),
  ('s720', 's', 's7', 'Estrutura da região do ombro', 'Ombro', 's7', 2, true),
  ('s730', 's', 's7', 'Estrutura do membro superior', 'Membro superior', 's7', 2, true),
  ('s740', 's', 's7', 'Estrutura da região pélvica', 'Pelve', 's7', 2, true),
  ('s750', 's', 's7', 'Estrutura do membro inferior', 'Membro inferior', 's7', 2, true),
  ('s760', 's', 's7', 'Estrutura da região do tronco', 'Tronco', 's7', 2, true),
  ('s770', 's', 's7', 'Estruturas musculoesqueléticas adicionais relacionadas com o movimento', 'Estruturas anexas', 's7', 2, true),
  -- d4 mobilidade
  ('d410', 'd', 'd4', 'Mudar a posição básica do corpo', 'Mudar de posição', 'd4', 2, true),
  ('d415', 'd', 'd4', 'Manter a posição do corpo', 'Manter a posição', 'd4', 2, true),
  ('d420', 'd', 'd4', 'Transferir-se', 'Transferências', 'd4', 2, true),
  ('d430', 'd', 'd4', 'Levantar e transportar objetos', 'Levantar objetos', 'd4', 2, true),
  ('d440', 'd', 'd4', 'Uso fino da mão', 'Motricidade fina', 'd4', 2, true),
  ('d445', 'd', 'd4', 'Uso da mão e do braço', 'Uso do braço', 'd4', 2, true),
  ('d450', 'd', 'd4', 'Andar', 'Andar', 'd4', 2, true),
  ('d455', 'd', 'd4', 'Deslocar-se por outros meios', 'Deslocar-se', 'd4', 2, true),
  ('d460', 'd', 'd4', 'Deslocar-se em diferentes localizações', 'Deslocar-se em locais', 'd4', 2, true),
  ('d465', 'd', 'd4', 'Deslocar-se utilizando equipamento', 'Deslocar-se com equipamento', 'd4', 2, true),
  ('d470', 'd', 'd4', 'Utilizar meios de transporte', 'Usar transportes', 'd4', 2, true),
  ('d475', 'd', 'd4', 'Conduzir', 'Conduzir', 'd4', 2, true),
  -- d5 autocuidado
  ('d510', 'd', 'd5', 'Lavar-se', 'Lavar-se', 'd5', 2, true),
  ('d520', 'd', 'd5', 'Cuidar de partes do corpo', 'Cuidar do corpo', 'd5', 2, true),
  ('d540', 'd', 'd5', 'Vestir-se', 'Vestir-se', 'd5', 2, true),
  ('d550', 'd', 'd5', 'Comer', 'Comer', 'd5', 2, true),
  ('d560', 'd', 'd5', 'Beber', 'Beber', 'd5', 2, true),
  ('d570', 'd', 'd5', 'Cuidar da própria saúde', 'Cuidar da saúde', 'd5', 2, true),
  -- d6 vida doméstica
  ('d630', 'd', 'd6', 'Preparar refeições', 'Preparar refeições', 'd6', 2, true),
  ('d640', 'd', 'd6', 'Realizar tarefas domésticas', 'Tarefas domésticas', 'd6', 2, true),
  ('d650', 'd', 'd6', 'Cuidar dos objetos da casa', 'Cuidar da casa', 'd6', 2, true),
  -- d8 e d9
  ('d850', 'd', 'd8', 'Trabalho remunerado', 'Trabalho', 'd8', 2, true),
  ('d855', 'd', 'd8', 'Trabalho não remunerado', 'Trabalho não remunerado', 'd8', 2, true),
  ('d860', 'd', 'd8', 'Transações económicas básicas', 'Transações básicas', 'd8', 2, true),
  ('d910', 'd', 'd9', 'Vida comunitária', 'Vida comunitária', 'd9', 2, true),
  ('d920', 'd', 'd9', 'Recreação e lazer', 'Recreação e lazer', 'd9', 2, true),
  ('d930', 'd', 'd9', 'Religião e espiritualidade', 'Religião', 'd9', 2, true),
  -- e ambiente
  ('e110', 'e', 'e1', 'Produtos ou substâncias para consumo pessoal', 'Produtos para consumo', 'e1', 2, true),
  ('e115', 'e', 'e1', 'Produtos e tecnologia para uso pessoal na vida diária', 'Tecnologia pessoal', 'e1', 2, true),
  ('e120', 'e', 'e1', 'Produtos e tecnologia para mobilidade pessoal dentro e fora de casa', 'Ajudas técnicas de mobilidade', 'e1', 2, true),
  ('e310', 'e', 'e3', 'Família imediata', 'Família', 'e3', 2, true),
  ('e320', 'e', 'e3', 'Amigos', 'Amigos', 'e3', 2, true),
  ('e340', 'e', 'e3', 'Prestadores de cuidados pessoais e assistentes pessoais', 'Cuidadores', 'e3', 2, true),
  ('e355', 'e', 'e3', 'Profissionais de saúde', 'Profissionais de saúde', 'e3', 2, true),
  ('e410', 'e', 'e4', 'Atitudes individuais da família imediata', 'Atitudes da família', 'e4', 2, true),
  ('e580', 'e', 'e5', 'Serviços, sistemas e políticas de saúde', 'Serviços de saúde', 'e5', 2, true),
  ('e590', 'e', 'e5', 'Serviços, sistemas e políticas de trabalho e emprego', 'Serviços de emprego', 'e5', 2, true)
on conflict (codigo) do update
  set descricao = excluded.descricao, descricao_curta = excluded.descricao_curta,
      componente = excluded.componente, capitulo = excluded.capitulo,
      codigo_pai = excluded.codigo_pai, nivel = excluded.nivel,
      usa_qualificador = excluded.usa_qualificador;

-- ---------------------------------------------------------------------------
-- 3. CIF — nível 3 (o detalhe que se usa na clínica)
-- ---------------------------------------------------------------------------
insert into public.cif_catalogo (codigo, componente, capitulo, descricao, descricao_curta, codigo_pai, nivel, usa_qualificador) values
  ('b2801', 'b', 'b2', 'Dor em uma ou mais regiões do corpo', 'Dor localizada', 'b280', 3, true),
  ('b2803', 'b', 'b2', 'Sensação de dor irradiada para outra região do corpo', 'Dor irradiada', 'b280', 3, true),
  ('b2804', 'b', 'b2', 'Sensação de dor em múltiplas regiões do corpo', 'Dor generalizada', 'b280', 3, true),
  ('b7100', 'b', 'b7', 'Mobilidade de uma única articulação', 'Mobilidade de uma articulação', 'b710', 3, true),
  ('b7101', 'b', 'b7', 'Mobilidade de várias articulações', 'Mobilidade de várias articulações', 'b710', 3, true),
  ('b7300', 'b', 'b7', 'Força dos músculos de um só membro ou grupo muscular', 'Força de um grupo muscular', 'b730', 3, true),
  ('b7600', 'b', 'b7', 'Controlo de movimentos voluntários simples', 'Controlo simples', 'b760', 3, true),
  ('b7601', 'b', 'b7', 'Controlo de movimentos voluntários complexos', 'Controlo complexo', 'b760', 3, true),
  ('b7602', 'b', 'b7', 'Coordenação de movimentos voluntários', 'Coordenação', 'b760', 3, true),
  ('d4500', 'd', 'd4', 'Andar distâncias curtas', 'Andar curtas distâncias', 'd450', 3, true),
  ('d4501', 'd', 'd4', 'Andar longas distâncias', 'Andar longas distâncias', 'd450', 3, true),
  ('d4502', 'd', 'd4', 'Andar sobre superfícies e terrenos diferentes', 'Andar em terrenos diferentes', 'd450', 3, true),
  ('d4503', 'd', 'd4', 'Andar à volta de obstáculos', 'Contornar obstáculos', 'd450', 3, true)
on conflict (codigo) do update
  set descricao = excluded.descricao, descricao_curta = excluded.descricao_curta,
      componente = excluded.componente, capitulo = excluded.capitulo,
      codigo_pai = excluded.codigo_pai, nivel = excluded.nivel,
      usa_qualificador = excluded.usa_qualificador;

-- ---------------------------------------------------------------------------
-- 4. CIF — nível 4 (localização anatómica da dor)
--    Este é o nível que se usa para caracterizar a dor do dia a dia.
-- ---------------------------------------------------------------------------
insert into public.cif_catalogo (codigo, componente, capitulo, descricao, descricao_curta, codigo_pai, nivel, usa_qualificador) values
  ('b28010', 'b', 'b2', 'Dor na cabeça e no pescoço', 'Dor cabeça/pescoço', 'b2801', 4, true),
  ('b28011', 'b', 'b2', 'Dor no peito', 'Dor no peito', 'b2801', 4, true),
  ('b28012', 'b', 'b2', 'Dor no estômago ou abdómen', 'Dor abdominal', 'b2801', 4, true),
  ('b28013', 'b', 'b2', 'Dor nas costas', 'Dor nas costas', 'b2801', 4, true),
  ('b28014', 'b', 'b2', 'Dor nos membros superiores', 'Dor membros superiores', 'b2801', 4, true),
  ('b28015', 'b', 'b2', 'Dor nos membros inferiores', 'Dor membros inferiores', 'b2801', 4, true),
  ('b28016', 'b', 'b2', 'Dor nas articulações', 'Dor articular', 'b2801', 4, true)
on conflict (codigo) do update
  set descricao = excluded.descricao, descricao_curta = excluded.descricao_curta,
      componente = excluded.componente, capitulo = excluded.capitulo,
      codigo_pai = excluded.codigo_pai, nivel = excluded.nivel,
      usa_qualificador = excluded.usa_qualificador;

-- ---------------------------------------------------------------------------
-- 5. CID-10 — subconjunto de MFR ordenado por relevância clínica
--    relevancia_mfr: 3 = aparece todos os dias, 0 = raro. Alimenta a ordem das
--    sugestões no ecrã, para o diagnóstico se escrever em segundos.
-- ---------------------------------------------------------------------------
insert into public.cid_catalogo (sistema, codigo, descricao, capitulo, grupo, relevancia_mfr) values
  -- Coluna vertebral
  ('CID-10','M54.5','Dor lombar baixa (lombalgia)','XIII','M50-M54',3),
  ('CID-10','M54.4','Lombalgia com irradiação (lumbociatalgia)','XIII','M50-M54',3),
  ('CID-10','M54.2','Cervicalgia','XIII','M50-M54',3),
  ('CID-10','M54.3','Ciática','XIII','M50-M54',3),
  ('CID-10','M54.1','Radiculopatia','XIII','M50-M54',3),
  ('CID-10','M51.1','Perturbação de disco lombar com radiculopatia','XIII','M50-M54',3),
  ('CID-10','M50.1','Perturbação de disco cervical com radiculopatia','XIII','M50-M54',2),
  ('CID-10','M53.1','Síndrome cervicobraquial','XIII','M50-M54',3),
  ('CID-10','M53.0','Síndrome cervicocraniana','XIII','M50-M54',2),
  ('CID-10','M53.3','Perturbações sacrococcígeas','XIII','M50-M54',1),
  ('CID-10','M47.8','Outras espondiloses','XIII','M45-M49',2),
  ('CID-10','M48.0','Estenose espinhal','XIII','M45-M49',2),
  ('CID-10','M43.1','Espondilolistese','XIII','M40-M43',2),
  ('CID-10','M45','Espondilite anquilosante','XIII','M45-M49',1),
  ('CID-10','M40.1','Cifose patológica','XIII','M40-M43',1),
  ('CID-10','M41','Escoliose','XIII','M40-M43',2),
  ('CID-10','M41.1','Escoliose idiopática juvenil','XIII','M40-M43',2),
  ('CID-10','M46.1','Sacroileíte','XIII','M45-M49',2),
  ('CID-10','M99.1','Complexo de subluxação (disfunção segmentar)','XIII','M95-M99',3),

  -- Ombro
  ('CID-10','M75.1','Síndrome da coifa dos rotadores','XIII','M70-M79',3),
  ('CID-10','M75.0','Capsulite adesiva do ombro (ombro congelado)','XIII','M70-M79',3),
  ('CID-10','M75.4','Síndrome de impacto do ombro','XIII','M70-M79',3),
  ('CID-10','M75.2','Tendinite bicipital','XIII','M70-M79',2),
  ('CID-10','M75.3','Tendinite calcificante do ombro','XIII','M70-M79',2),
  ('CID-10','M75.5','Bursite do ombro','XIII','M70-M79',2),

  -- Cotovelo, punho e mão
  ('CID-10','M77.1','Epicondilite lateral (cotovelo de tenista)','XIII','M70-M79',3),
  ('CID-10','M77.0','Epicondilite medial','XIII','M70-M79',2),
  ('CID-10','M77.9','Entesopatia não especificada','XIII','M70-M79',2),
  ('CID-10','G56.0','Síndrome do túnel cárpico','VI','G50-G59',3),
  ('CID-10','G56.2','Lesão do nervo cubital','VI','G50-G59',1),
  ('CID-10','M65.3','Dedo em gatilho','XIII','M65-M68',2),
  ('CID-10','M65.4','Tenossinovite estenosante (dedo em gatilho)','XIII','M65-M68',2),

  -- Anca e joelho
  ('CID-10','M16.1','Coxartrose primária','XIII','M15-M19',3),
  ('CID-10','M16.9','Coxartrose não especificada','XIII','M15-M19',2),
  ('CID-10','M17.1','Gonartrose primária','XIII','M15-M19',3),
  ('CID-10','M17.9','Gonartrose não especificada','XIII','M15-M19',2),
  ('CID-10','M15.0','Artrose primária generalizada','XIII','M15-M19',2),
  ('CID-10','M19.0','Artrose primária de outras articulações','XIII','M15-M19',2),
  ('CID-10','M23.2','Lesão do menisco por rotura antiga','XIII','M20-M25',3),
  ('CID-10','M23.6','Outras roturas espontâneas do ligamento cruzado','XIII','M20-M25',2),
  ('CID-10','M22.2','Perturbações femoropatelares','XIII','M20-M25',3),
  ('CID-10','M25.5','Dor articular','XIII','M20-M25',3),
  ('CID-10','M25.6','Rigidez articular','XIII','M20-M25',3),
  ('CID-10','M76.5','Tendinite rotuliana','XIII','M70-M79',2),
  ('CID-10','M70.4','Bursite pré-patelar','XIII','M70-M79',1),
  ('CID-10','S83.5','Entorse e distensão do ligamento cruzado do joelho','XIX','S80-S89',2),
  ('CID-10','S83.4','Entorse do ligamento colateral do joelho','XIX','S80-S89',2),

  -- Tornozelo e pé
  ('CID-10','S93.4','Entorse do tornozelo','XIX','S90-S99',3),
  ('CID-10','M72.2','Fibromatose plantar (fasciíte plantar)','XIII','M70-M79',3),
  ('CID-10','M77.3','Esporão do calcâneo','XIII','M70-M79',2),
  ('CID-10','M20.1','Hallux valgus','XIII','M20-M25',1),
  ('CID-10','M79.6','Dor em membro','XIII','M70-M79',2),
  ('CID-10','M79.2','Neuralgia e neurite não especificadas','XIII','M70-M79',2),

  -- Dor crónica e mecanismos de amplificação central
  ('CID-10','M79.7','Fibromialgia','XIII','M70-M79',3),
  ('CID-10','R52.1','Dor crónica intratável','XVIII','R50-R53',3),
  ('CID-10','R52.2','Outra dor crónica','XVIII','R50-R53',3),
  ('CID-10','M89.0','Algoneurodistrofia (síndrome de dor regional complexa)','XIII','M86-M90',2),
  ('CID-10','G54.0','Perturbações do plexo braquial','VI','G50-G59',1),
  ('CID-10','G57.0','Lesão do nervo ciático','VI','G50-G59',2),

  -- Neurologia com relevância em reabilitação
  ('CID-10','I63.9','Enfarte cerebral não especificado (AVC)','IX','I60-I69',3),
  ('CID-10','G81.9','Hemiplegia não especificada','VI','G80-G83',3),
  ('CID-10','G82.2','Paraparésia não especificada','VI','G80-G83',2),
  ('CID-10','G20','Doença de Parkinson','VI','G20-G26',2),
  ('CID-10','G24.3','Torcicolo espasmódico','VI','G20-G26',1),
  ('CID-10','G35','Esclerose múltipla','VI','G35-G37',2),
  ('CID-10','G51.0','Paralisia de Bell','VI','G50-G59',2),
  ('CID-10','G62.9','Polineuropatia não especificada','VI','G60-G64',2),
  ('CID-10','G80.9','Paralisia cerebral não especificada','VI','G80-G83',2),

  -- Pós-cirúrgico
  ('CID-10','Z96.6','Presença de implante ortopédico articular','XXI','Z95-Z98',3),
  ('CID-10','Z47.1','Cuidados de seguimento após artroplastia articular','XXI','Z40-Z54',3),
  ('CID-10','M96.6','Complicação de implante ortopédico','XIII','M95-M99',2),
  ('CID-10','T84.5','Infecção e reação inflamatória devidas a prótese articular','XIX','T80-T88',1),

  -- Cardiorrespiratório
  ('CID-10','J44.9','Doença pulmonar obstrutiva crónica não especificada (DPOC)','X','J40-J47',3),
  ('CID-10','J45.9','Asma não especificada','X','J40-J47',2),
  ('CID-10','I50.9','Insuficiência cardíaca não especificada','IX','I30-I52',2),
  ('CID-10','I10','Hipertensão arterial essencial','IX','I10-I15',2),
  ('CID-10','R06.0','Dispneia','XVIII','R00-R09',1),

  -- Geriatria, fragilidade e quedas
  ('CID-10','M81.0','Osteoporose pós-menopáusica','XIII','M80-M85',2),
  ('CID-10','M80.0','Osteoporose pós-menopáusica com fratura patológica','XIII','M80-M85',2),
  ('CID-10','R26.2','Dificuldade em andar, não classificada em outra parte','XVIII','R25-R29',3),
  ('CID-10','R26.3','Imobilidade','XVIII','R25-R29',2),
  ('CID-10','R27.0','Ataxia não especificada','XVIII','R25-R29',1),
  ('CID-10','W19','Queda não especificada','XX','W00-X59',2),
  ('CID-10','R41.3','Outro esquecimento (défice cognitivo)','XVIII','R40-R46',1),

  -- Fatores psicossociais (o modelo biopsicossocial exige-os no diagnóstico)
  ('CID-10','F41.1','Perturbação de ansiedade generalizada','V','F40-F48',2),
  ('CID-10','F32.1','Episódio depressivo moderado','V','F30-F39',2),
  ('CID-10','F45.4','Dor somatoforme persistente','V','F40-F48',2),
  ('CID-10','Z73.0','Esgotamento (burnout)','XXI','Z70-Z76',1),

  -- Reumatologia
  ('CID-10','M06.9','Artrite reumatoide não especificada','XIII','M05-M14',3),
  ('CID-10','M10.9','Gota não especificada','XIII','M05-M14',2),
  ('CID-10','M35.3','Polimialgia reumática','XIII','M30-M36',1),
  ('CID-10','M32.9','Lúpus eritematoso disseminado não especificado','XIII','M30-M36',1),

  -- Pediatria
  ('CID-10','Q65.0','Luxação congénita da anca unilateral','XVII','Q65-Q79',2),
  ('CID-10','F82','Perturbação específica do desenvolvimento motor','V','F80-F89',2),
  ('CID-10','R62.0','Atraso do desenvolvimento','XVIII','R62',1)
on conflict (sistema, codigo) do update
  set descricao = excluded.descricao, capitulo = excluded.capitulo,
      grupo = excluded.grupo, relevancia_mfr = excluded.relevancia_mfr;

-- ---------------------------------------------------------------------------
-- 6. Verificação das seeds de classificação
--    Um catálogo incompleto em silêncio é pior do que não ter catálogo: o
--    clínico procura, não encontra e volta ao papel.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cif    integer;
  v_cid    integer;
  v_problema integer;
  v_erros  text[] := '{}';
begin
  select count(*) into v_cif from public.cif_catalogo;
  select count(*) into v_cid from public.cid_catalogo;

  raise notice 'Catálogos — CIF: % códigos, CID-10: % códigos', v_cif, v_cid;

  if v_cif < 100 then v_erros := v_erros || format('CIF insuficiente (%s)', v_cif); end if;
  if v_cid < 90  then v_erros := v_erros || format('CID insuficiente (%s)', v_cid); end if;

  -- Integridade hierárquica: nenhum pai pode estar em falta.
  select count(*) into v_problema
    from public.cif_catalogo f
   where f.codigo_pai is not null
     and not exists (select 1 from public.cif_catalogo p where p.codigo = f.codigo_pai);
  if v_problema > 0 then
    v_erros := v_erros || format('%s códigos CIF com pai inexistente', v_problema);
  end if;

  -- Coerência do componente: o primeiro caractere do código define-o.
  select count(*) into v_problema from public.cif_catalogo where componente <> left(codigo, 1);
  if v_problema > 0 then
    v_erros := v_erros || format('%s códigos CIF com componente incoerente', v_problema);
  end if;

  if array_length(v_erros, 1) > 0 then
    raise exception 'Seeds de classificação com problemas: %', array_to_string(v_erros, '; ');
  end if;

  raise notice 'Catálogos CIF/CID verificados com sucesso.';
end $$;


-- ----------------------------------------------------------------------------
-- 0005_catalogo_medicoes.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0005 — Catálogo de medições gerado das articulações
--
-- PORQUE É UM SEED E NÃO UMA MIGRAÇÃO
-- ============================================================================
-- A primeira versão disto foi escrita como migração 0016, e não fazia nada: as
-- migrações correm ANTES dos seeds, e é o seed 0001 que cria as articulações.
-- O `insert … select … from articulacoes` cruzava com uma tabela vazia, inseria
-- zero linhas e não dava erro — falhava em silêncio, que é a pior forma de
-- falhar. O teste `testar_catalogo_medicoes.mjs` apanhou-o.
--
-- O SITIO CERTO É AQUI: depois das articulações existirem, e depois de o seed
-- 0001 ter criado os 31 tipos escritos à mão.
--
-- ----------------------------------------------------------------------------
-- O PROBLEMA QUE ISTO RESOLVE
-- ----------------------------------------------------------------------------
-- O ecrã de avaliação grava as medições com o código construído a partir da
-- articulação e do movimento escolhidos:
--
--     adm_<articulacao>_<movimento>      ex.: adm_glenoumeral_d_flexao
--     forca_<articulacao>_<movimento>    ex.: forca_glenoumeral_d_flexao
--     dor_movimento_<articulacao>        ex.: dor_movimento_glenoumeral_d
--
-- O catálogo `tipos_medicao` tinha 31 entradas escritas à mão, e NENHUMA delas
-- correspondia a esses códigos. Como o gráfico de evolução lê o catálogo pelo
-- código, cada medição ficava sem unidade, sem intervalo e — o mais grave —
-- sem direção de melhoria. Uma amplitude a subir e uma dor a subir apareciam da
-- mesma forma.
--
-- Em vez de escrever 184 entradas à mão (e voltar a ficar desatualizado quando
-- alguém acrescentar uma articulação), o catálogo é GERADO a partir de
-- `articulacoes`. Acrescentar uma articulação ao catálogo anatómico passa a
-- acrescentar as medições respetivas, sem ninguém se lembrar de o fazer.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Amplitudes: uma por articulação e movimento
--
-- `min_valor = -30` de propósito. Antes era 0, e isso impedia registar
-- hiperextensão do joelho (geno recurvatum) ou do cotovelo — valores negativos
-- clinicamente significativos que ficavam impossíveis de escrever.
--
-- O teto é a referência anatómica (`adm_normal`) com 20% de folga: uma
-- amplitude pode ser maior do que o normal (hipermobilidade), mas um valor três
-- vezes acima do normal é um erro de escrita, não um achado clínico.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'adm_' || a.codigo || '_' || m.movimento,
  'ADM ' || initcap(replace(m.movimento, '_', ' ')) || ' — ' || a.nome,
  'amplitude',
  'graus',
  0,
  'maior_melhor',
  -30,
  greatest(coalesce((a.adm_normal ->> m.movimento)::numeric, 180) * 1.2, 180),
  true,
  a.codigo,
  m.movimento,
  a.ordem
from public.articulacoes a
cross join lateral unnest(a.movimentos) as m(movimento)
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 2. Força: uma por articulação e movimento
--
-- A escala de Oxford (MRC) pontua de 0 a 5, em passos de MEIA unidade — daí
-- `decimais = 1`. Um 4+ é 4,5; um 3- é 2,5. Sem a casa decimal, a distinção
-- entre 4 e 4+ (que muda a conduta) não era registável.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'forca_' || a.codigo || '_' || m.movimento,
  'Força (Oxford) ' || initcap(replace(m.movimento, '_', ' ')) || ' — ' || a.nome,
  'forca',
  'pontos',
  1,
  'maior_melhor',
  0,
  5,
  true,
  a.codigo,
  m.movimento,
  a.ordem + 1
from public.articulacoes a
cross join lateral unnest(a.movimentos) as m(movimento)
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 3. Dor ao movimento: uma por articulação
--
-- Avalia-se por articulação, não por movimento: é a resposta global da
-- articulação à mobilização, não de um movimento isolado.
-- ---------------------------------------------------------------------------
insert into public.tipos_medicao
  (clinica_id, codigo, nome, categoria, unidade, decimais, melhor_direcao,
   min_valor, max_valor, permite_lado, articulacao_codigo, movimento, ordem)
select
  null,
  'dor_movimento_' || a.codigo,
  'Dor ao movimento — ' || a.nome,
  'dor',
  'pontos',
  0,
  'menor_melhor',
  0,
  10,
  true,
  a.codigo,
  null,
  a.ordem + 2
from public.articulacoes a
where a.ativo
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 4. Corrigir as entradas escritas à mão
--
-- As 31 entradas originais ficaram com `min_valor = 0` e continuam a impedir
-- registar hiperextensão. A correção aplica-se a todas as medições de
-- amplitude, não só às novas — as antigas são as que alguns ecrãs ainda usam.
-- ---------------------------------------------------------------------------
update public.tipos_medicao
   set min_valor = -30
 where categoria in ('amplitude', 'movimento')
   and min_valor is not null
   and min_valor > -30;

-- A força em Oxford tem meias unidades. A entrada escrita à mão (`forca_oxford`)
-- ficou com 0 casas decimais, e com isso o campo arredondava 4,5 para 4 ou 5 —
-- e a distinção 4 / 4+ / 5 perdia-se, que é precisamente a que muda a conduta.
update public.tipos_medicao
   set decimais = 1
 where categoria = 'forca'
   and decimais = 0
   and (max_valor is null or max_valor <= 5);


-- ---------------------------------------------------------------------------
-- 5. VERIFICAÇÃO
--
-- Não é decoração: é o que faz o seed dizer se falhou em silêncio. Foi
-- exatamente o que faltou na primeira versão, escrita como migração, que corria
-- antes de existirem articulações.
-- ---------------------------------------------------------------------------
do $$
declare
  v_articulacoes int;
  v_esperadas    int;
  v_amplitudes   int;
  v_forcas       int;
  v_dores        int;
  v_sem_direcao  int;
begin
  select count(*) into v_articulacoes from public.articulacoes where ativo;
  select coalesce(sum(array_length(a.movimentos, 1)), 0)
    into v_esperadas
    from public.articulacoes a where a.ativo;

  select count(*) into v_amplitudes from public.tipos_medicao where codigo like 'adm\_%';
  select count(*) into v_forcas     from public.tipos_medicao where codigo like 'forca\_%';
  select count(*) into v_dores      from public.tipos_medicao where codigo like 'dor\_movimento\_%';

  if v_articulacoes = 0 then
    raise exception
      'Nao ha articulacoes ativas. O seed 0001 tem de correr antes deste — sem elas o catalogo de medicoes fica vazio e registar amplitudes falha.';
  end if;

  if v_amplitudes < v_esperadas then
    raise exception
      'Faltam amplitudes: % no catalogo para % combinacoes de articulacao e movimento.',
      v_amplitudes, v_esperadas;
  end if;

  if v_forcas < v_esperadas then
    raise exception 'Faltam forcas: % no catalogo para % combinacoes.', v_forcas, v_esperadas;
  end if;

  if v_dores < v_articulacoes then
    raise exception 'Faltam dores ao movimento: % no catalogo para % articulacoes.', v_dores, v_articulacoes;
  end if;

  /* Uma medição sem direção de melhoria é uma medição que mente no gráfico. */
  select count(*) into v_sem_direcao
    from public.tipos_medicao
   where melhor_direcao is null or melhor_direcao = '';
  if v_sem_direcao > 0 then
    raise exception 'Ha % medicoes sem direcao de melhoria.', v_sem_direcao;
  end if;

  raise notice 'Catalogo de medicoes: % amplitudes, % forcas e % dores ao movimento, sobre % articulacoes.',
    v_amplitudes, v_forcas, v_dores, v_articulacoes;
end $$;


-- ----------------------------------------------------------------------------
-- 0006_ecras_e_visibilidade.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0006 — Catálogo de ecrãs e visibilidade por omissão
--
-- PORQUE ISTO É UM SEED, E PORQUE FAZ FALTA
-- ============================================================================
-- A migração 0014 criou `ecras` e `perfil_visibilidade`, as funções
-- `clinia.ve_ecra()` / `clinia.pode_escrever_ecra()`, e as políticas de RLS da
-- faturação que perguntam a essas funções. Ficou tudo por semear.
--
-- Consequência, se este seed não correr: `ve_ecra('faturacao')` devolve sempre
-- falso porque o catálogo está vazio. As políticas de escrita da faturação
-- recusam TUDO, e o administrador só passa pelo atalho de `e_admin()` que existe
-- dentro da função. Ou seja: uma clínica sem administrador presente não emite
-- uma única fatura, e não há mensagem que explique porquê.
--
-- É o mesmo tipo de armadilha do catálogo de medições (seed 0005): uma peça de
-- infraestrutura criada e nunca ligada, que falha em silêncio.
--
-- PORQUE É QUE A ATRIBUIÇÃO POR OMISSÃO TEM DE SER GENEROSA
-- ============================================================================
-- Impor visibilidade por perfil sobre uma clínica em funcionamento tira acesso
-- a quem já trabalhava. A alternativa — começar sem nada atribuído — tranca
-- toda a gente fora no dia da atualização.
--
-- A regra deste seed: cada perfil recebe, por omissão, o que a aplicação já lhe
-- dava antes de existir visibilidade configurável. Quem quiser restringir,
-- restringe depois, ecrã a ecrã, e vê imediatamente quem perde o quê. O
-- contrário — dar por omissão o mínimo e pedir ao administrador para conceder
-- tudo outra vez — é pedir-lhe para reconstruir uma configuração que já estava
-- certa.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. CATÁLOGO DE ECRÃS
--
-- `area` decide o que o ecrã REVELA, e não é o mesmo que o perfil de quem o vê:
-- a receção precisa da agenda (identificação do utente) mas não pode ver
-- diagnóstico. `obrigatorio` marca os ecrãs sem os quais não há processo
-- clínico nem faturação legal — existe para a interface poder explicar porque
-- não deixa desligar, em vez de mostrar uma caixa que não faz nada.
-- ---------------------------------------------------------------------------
insert into public.ecras (codigo, nome, grupo, ordem, area, visivel_em, obrigatorio)
values
  ('agenda', 'Agenda', 'Clínica', 10, 'agenda',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro,rececao,gestao}', true),

  ('utentes', 'Utentes', 'Clínica', 20, 'administrativa',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro,rececao,gestao}', true),

  /* O CÓDIGO DO ECRÃ É A ROTA DO CLIENTE. Uma coisa, um nome.
   *
   * Estes três estavam no SINGULAR — `episodio`, `plano`, `sessao` — e as rotas
   * são os plurais. A navegação pergunta pelo plural, o catálogo tem o singular,
   * a resposta é «não», e o item desaparece do menu. O administrador ficava sem
   * Episódios, Planos e Sessões, sem um único erro.
   *
   * A migração 0022 renomeia as linhas das instalações que já existiam; aqui
   * nascem com o nome certo. */
  ('episodios', 'Episódios', 'Processo clínico', 30, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro}', false),

  ('avaliacao', 'Avaliação', 'Processo clínico', 40, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo}', false),

  ('planos', 'Plano e objetivos', 'Processo clínico', 50, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo}', false),

  ('sessoes', 'Sessões', 'Processo clínico', 60, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro}', false),

  ('evolucao', 'Evolução', 'Processo clínico', 70, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo}', false),

  ('relatorios', 'Relatórios', 'Documentos', 80, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo}', false),

  ('requisicoes', 'Requisições e receituário', 'Documentos', 90, 'clinica',
   '{administrador,fisiatra}', false),

  /* FATURAÇÃO. A área é `faturacao` e não `clinica`: o ecrã mostra atos
     praticados e valores, e NÃO revela diagnóstico. É essa separação que
     permite dar a faturação à gestão sem lhe dar o processo clínico. */
  ('faturacao', 'Faturação', 'Faturação', 100, 'faturacao',
   '{administrador,gestao,rececao}', false),

  ('faturacao_config', 'Dados fiscais e séries', 'Faturação', 110, 'faturacao',
   '{administrador,gestao}', false),

  /* INDICADORES DE GESTÃO. Área `gestao`, e não `clinica`: são números
     agregados — faturação, ocupação, produtividade — e não registos de
     doentes. É preciso separar os dois: é legítimo a gestão querer saber
     quantas sessões se fizeram, e NÃO é legítimo que veja o que se escreveu
     sobre cada utente. Um ecrã só com agregados serve a primeira coisa sem
     fazer a segunda.

     Se um dia este ecrã mostrar conteúdo clínico individual, deixa de poder
     estar na área `gestao` — a área é o que decide quem o pode receber. */
  ('gestao', 'Indicadores', 'Sistema', 125, 'gestao',
   '{administrador,gestao}', false),

  ('administracao', 'Administração', 'Sistema', 120, 'gestao',
   '{administrador}', false),

  ('visibilidade', 'Ecrãs por perfil', 'Sistema', 130, 'gestao',
   '{administrador}', false),

  ('configuracao', 'Configuração', 'Sistema', 140, 'gestao',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro,rececao,gestao}', false),

  ('portal', 'Os meus dados', 'Portal do utente', 200, 'administrativa',
   '{utente}', false),

  /* O CONSENTIMENTO ONLINE. O código tem de ser igual à rota do cliente
     (`C.ecras.consentimento`), como todos os outros — a migração 0022 corrigiu
     três que não eram, e `testar_codigos_de_ecra.mjs` impede que volte a
     acontecer.
     
     Não aparece no menu lateral porque os dois ecrãs que o usam são o do UTENTE
     (público) e a aba de consentimentos da ficha. Existe no catálogo porque a
     rota tem de estar registada para o link que enviamos abrir. */
  ('consentimento', 'Consentimento informado', 'Processo clínico', 150, 'clinica',
   '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro,rececao,gestao,utente}', false)

on conflict (codigo) do update
   set nome        = excluded.nome,
       grupo       = excluded.grupo,
       ordem       = excluded.ordem,
       area        = excluded.area,
       visivel_em  = excluded.visivel_em,
       obrigatorio = excluded.obrigatorio,
       updated_at  = now();


-- ---------------------------------------------------------------------------
-- 2. PERFIS QUE NÃO SÃO EQUIPA
--
-- `utente` é o portal: só vê os seus dados. Não entra nas regras da equipa.
-- `gestao` e `rececao` são administrativos: nunca recebem conteúdo clínico,
-- independentemente do que se configurar — por isso as linhas abaixo os limitam
-- aos ecrãs de área não clínica.
-- ---------------------------------------------------------------------------
do $$
declare
  v_clinica record;
  v_perfis_clinicos text[] := array[
    'fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
    'terapeuta_da_fala','psicologo','enfermeiro'
  ];
  v_perfis_todos text[] := array[
    'administrador','fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
    'terapeuta_da_fala','psicologo','enfermeiro','rececao','gestao'
  ];
  v_ecra record;
  v_perfil text;
  v_permitidos text[];
begin
  /* Sinalizador de transação: estas escritas são o SEMEIO da visibilidade por
     omissão, e não um pedido de um utilizador. Sem isto, o gatilho
     `clinia.proteger_visibilidade()` (migração 0019) recusaria — corretamente,
     para um utilizador, mas não para o sistema a preparar uma clínica. */
  perform set_config('clinia.a_semear_visibilidade', 'sim', true);

  for v_clinica in select id from public.clinicas loop

    for v_ecra in select * from public.ecras where ativo loop

      /* Quem pode receber este ecrã: a lista do próprio ecrã, intersetada com
         os perfis da equipa. O ecrã do portal não entra aqui — é tratado à
         parte, porque o utente não é equipa. */
      if v_ecra.codigo = 'portal' then
        continue;
      end if;

      foreach v_perfil in array v_perfis_todos loop
        /* `visivel_em` é um array de `perfil_tipo` (enum) e `v_perfil` é texto.
           O cast explícito a `text[]` é obrigatório: sem ele o PostgreSQL tenta
           `text = perfil_tipo`, não encontra o operador e a instalação aborta. */
        if v_perfil = any (v_ecra.visivel_em::text[]) then

          insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
          values (
            v_clinica.id,
            v_perfil::public.perfil_tipo,
            v_ecra.id,
            true,
            /* Só leitura por omissão em dois casos, e são decisões clínicas:

               · A GESTÃO vê a faturação para conferir e reconciliar, mas não
                 emite documentos fiscais. Emitir é um ato com consequências
                 legais; conferir não.
               · A RECEÇÃO vê os ecrãs administrativos para admitir utentes, mas
                 não altera o que já lá está — o processo é da equipa clínica. */
            (v_perfil = 'gestao' and v_ecra.area = 'faturacao')
            or (v_perfil = 'rececao' and v_ecra.area in ('clinica'))
          )
          on conflict (clinica_id, perfil, ecra_id) do nothing;

        end if;
      end loop;

    end loop;

    /* O portal do utente: só o próprio. */
    insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
    select v_clinica.id, 'utente'::public.perfil_tipo, e.id, true, true
      from public.ecras e
     where e.codigo = 'portal'
    on conflict (clinica_id, perfil, ecra_id) do nothing;

  end loop;

  /* Repor: a partir daqui, qualquer escrita volta a ser julgada como um pedido
     de utilizador. */
  perform set_config('clinia.a_semear_visibilidade', 'nao', true);
end $$;


-- ---------------------------------------------------------------------------
-- 3. UMA CLÍNICA NOVA NASCE CONFIGURADA
--
-- O mesmo problema do MFR na migração 0013: numa instalação de raiz, este seed
-- corre antes do bootstrap, e é o bootstrap que cria a clínica. Sem este
-- gatilho, a clínica nova ficava com o catálogo de ecrãs mas sem uma única
-- linha de visibilidade — e a faturação recusava tudo.
--
-- Reaproveita a mesma decisão do MFR: nascer com o que faz sentido, e deixar o
-- administrador restringir depois.
-- ---------------------------------------------------------------------------
create or replace function clinia.semear_visibilidade_da_clinica()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perfis_todos text[] := array[
    'administrador','fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
    'terapeuta_da_fala','psicologo','enfermeiro','rececao','gestao'
  ];
  v_ecra record;
  v_perfil text;
begin
  /* Sinalizador de transação: diz ao gatilho `clinia.proteger_visibilidade()`
     (migração 0019) que estas escritas são o SEMEIO, e não um pedido de um
     utilizador. Sem isto, criar uma clínica falharia — o gatilho julgaria o
     sistema como se fosse alguém a tentar conceder-se permissões. */
  perform set_config('clinia.a_semear_visibilidade', 'sim', true);

  for v_ecra in select * from public.ecras where ativo and codigo <> 'portal' loop
    foreach v_perfil in array v_perfis_todos loop
      /* Mesmo cast do bloco acima: `perfil_tipo` (enum) contra texto. */
      if v_perfil = any (v_ecra.visivel_em::text[]) then
        insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
        values (
          new.id, v_perfil::public.perfil_tipo, v_ecra.id, true,
          (v_perfil = 'gestao' and v_ecra.area = 'faturacao')
          or (v_perfil = 'rececao' and v_ecra.area = 'clinica')
        )
        on conflict (clinica_id, perfil, ecra_id) do nothing;
      end if;
    end loop;
  end loop;

  insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
  select new.id, 'utente'::public.perfil_tipo, e.id, true, true
    from public.ecras e where e.codigo = 'portal'
  on conflict (clinica_id, perfil, ecra_id) do nothing;

  /* Repor o sinalizador: a partir daqui, qualquer escrita nesta transação volta
     a ser julgada como um pedido de utilizador. */
  perform set_config('clinia.a_semear_visibilidade', 'nao', true);

  return new;
end $$;

comment on function clinia.semear_visibilidade_da_clinica() is
  'Da visibilidade por omissao a uma clinica nova. Sem isto, a faturacao de uma clinica recem-criada recusaria tudo sem explicar porque.';

drop trigger if exists t_clinica_nova_visibilidade on public.clinicas;
create trigger t_clinica_nova_visibilidade
  after insert on public.clinicas
  for each row execute function clinia.semear_visibilidade_da_clinica();


-- ---------------------------------------------------------------------------
-- 4. VERIFICAÇÃO
--
-- Uma verificação que falha alto, e não um aviso: sem visibilidade semeada, a
-- faturação não funciona, e isso não é um detalhe de qualidade — é a função
-- principal em falta.
-- ---------------------------------------------------------------------------
do $$
declare
  v_ecras      int;
  v_clinicas   int;
  v_regras     int;
  v_sem_regras text[];
begin
  select count(*) into v_ecras from public.ecras where ativo;
  if v_ecras < 10 then
    raise exception 'Catalogo de ecras incompleto: % entradas.', v_ecras;
  end if;

  select count(*) into v_clinicas from public.clinicas;
  select count(*) into v_regras from public.perfil_visibilidade;

  /* Nenhuma clínica pode ficar sem regras: `ve_ecra` responderia sempre falso
     (fora do atalho do administrador) e a faturação recusaria tudo. */
  select coalesce(array_agg(c.nome), '{}') into v_sem_regras
    from public.clinicas c
   where not exists (
     select 1 from public.perfil_visibilidade v where v.clinica_id = c.id
   );

  if array_length(v_sem_regras, 1) > 0 then
    raise exception
      'Clinicas sem visibilidade configurada (a faturacao vai recusar tudo): %',
      array_to_string(v_sem_regras, ', ');
  end if;

  /* O administrador tem de ver a faturação — é ele que a vai configurar. */
  if v_clinicas > 0 and not exists (
    select 1
      from public.perfil_visibilidade v
      join public.ecras e on e.id = v.ecra_id
     where v.perfil = 'administrador' and e.codigo = 'faturacao' and v.visivel
  ) then
    raise exception 'O administrador ficou sem acesso ao ecra de faturacao.';
  end if;

  raise notice 'Visibilidade: % ecras, % regras em % clinica(s).', v_ecras, v_regras, v_clinicas;
end $$;


-- ----------------------------------------------------------------------------
-- 0007_proms_e_mcid.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · migração 0020 — Instrumentos que provam o que mudou
--
-- TRÊS COISAS, E A RAZÃO DE ESTAREM JUNTAS
-- ============================================================================
--   1. `perfis.especialidade` deixa de ser obrigatória para quem não trata.
--   2. `escalas` ganha MCID — a diferença mínima que o doente sente.
--   3. Chegam quatro PROMs que faltavam: ODI, QuickDASH, KOOS e Berg.
--
-- A ligação entre elas é o que a auditoria clínica chamou de maior lacuna do
-- produto: **sem MCID, um número não diz se o doente melhorou**. Uma EVA que
-- desce de 7 para 5 é uma melhoria de 2 pontos — e 2 pontos é ou não é
-- significativo? Sem essa resposta, o software produz números e o clínico
-- continua a decidir «por alto», que é exatamente o que se queria evitar.
--
-- O MCID resolve isso, e resolve uma segunda coisa que interessa ao negócio:
-- é o que transforma «acho que está melhor» em algo que se escreve num
-- relatório para uma seguradora ou para uma junta médica.
--
-- ----------------------------------------------------------------------------
-- PORQUE ESTES QUATRO, E NÃO OUTROS
-- ----------------------------------------------------------------------------
-- Foram os que o próprio documento do projeto chamou essenciais, e são os que
-- cobrem as três regiões que uma clínica de reabilitação vê todos os dias:
--
--     ODI        lombalgia          — a queixa mais comum em MFR
--     QuickDASH  membro superior    — ombro, cotovelo, punho e mão
--     KOOS       joelho             — gonartrose, LCA, prótese
--     Berg       equilíbrio e queda — o que decide se um idoso pode ir a casa
--
-- Todos têm tradução portuguesa validada e são de uso livre para avaliação
-- clínica. A coluna `licenca` fica preenchida para que ninguém tenha de
-- descobrir isso depois.
-- ============================================================================



-- ============================================================================
-- ESTE FICHEIRO E UM SEED, E A DISTINCAO IMPORTA
--
-- As migracoes correm ANTES dos seeds, e as escalas da EVA, NPRS e Barthel sao
-- criadas pelo seed 0002. A primeira versao disto estava numa migracao e os
-- `update` abaixo nao alteravam nada, porque as escalas ainda nao existiam —
-- falhava em silencio. O esquema vive na migracao 0020; os dados vivem aqui.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. MCID DAS ESCALAS QUE JA EXISTIAM
-- ---------------------------------------------------------------------------
/* O MCID das escalas que já existiam. A EVA e a NPRS são as mais usadas em MFR
   e têm um MCID bem estabelecido: 2 pontos numa escala de 0 a 10, ou cerca de
   30% do valor inicial — o que for maior.

   O Barthel não tem um MCID consensual em pontos absolutos; a literatura aponta
   para uma mudança de 1 categoria funcional. Fica com o valor mais citado, e a
   fonte escrita, para quem discordar poder corrigir. */
update public.escalas set mcid = 2, mcid_melhoria = 2, mcid_pior = 2,
       mcid_fonte = 'Farrar et al. 2001 (2 pontos em 10, ou 30% do valor inicial)',
       periodo_recordacao = 'Neste momento'
 where codigo = 'eva' and clinica_id is null;

update public.escalas set mcid = 2, mcid_melhoria = 2, mcid_pior = 2,
       mcid_fonte = 'Farrar et al. 2001 (2 pontos em 10)',
       periodo_recordacao = 'Neste momento'
 where codigo = 'nprs' and clinica_id is null;

update public.escalas set mcid = 1.5,
       mcid_fonte = 'Hsieh et al. 2007 (aproximadamente uma categoria funcional)',
       periodo_recordacao = 'Nas ultimas 48 horas',
       modo_administracao = 'observacao'
 where codigo = 'barthel' and clinica_id is null;


-- ---------------------------------------------------------------------------
-- 3. ODI — Índice de Incapacidade de Oswestry
--
-- Dez secções, cada uma de 0 a 5, sobre o que a lombalgia impede de fazer.
-- É o instrumento de referência para lombalgia, e o que as seguradoras
-- portuguesas reconhecem.
--
-- `modo_administracao = 'utente'`: é um questionário que o doente responde
-- sozinho. Está marcado assim porque é isso que permite enviá-lo ao portal sem
-- o clínico o ler em voz alta — e porque quem responde é o doente, não quem
-- observa.
--
-- PONTUAÇÃO: a soma dá 0 a 100. Cada item vale 0 a 5 e o resultado é
-- percentual (soma × 2). O `peso = 2` faz isso dentro do motor de cálculo que
-- já existe, em vez de exigir uma função nova.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica, licenca,
   mcid, mdc, mcid_melhoria, mcid_pior, mcid_fonte,
   modo_administracao, periodo_recordacao)
values
  (null, 'odi', 'Índice de Incapacidade de Oswestry', 'ODI', '2.1a', 'funcao', 'soma',
   0, 100,
   '[{"max":20,"rotulo":"incapacidade mínima","gravidade":"ausente"},
     {"max":40,"rotulo":"incapacidade moderada","gravidade":"leve"},
     {"max":60,"rotulo":"incapacidade grave","gravidade":"moderada"},
     {"max":80,"rotulo":"incapacidade muito grave","gravidade":"grave"},
     {"max":100,"rotulo":"acamado ou com sintomas exagerados","gravidade":"grave"}]'::jsonb,
   false, array['adulto','senior'], 'mfr',
   'Dez secções sobre o que a lombalgia impede de fazer (cuidados pessoais, levantar pesos, andar, sentar, estar de pé, dormir, vida sexual, vida social, viajar). Cada secção de 0 a 5; o total é percentual.',
   'Fairbank & Pynsent 2000; versão portuguesa validada',
   'Uso livre para avaliação clínica; verificar condições para uso comercial',
   10, 10, 10, 10,
   'Ostelo et al. 2008 (revisão sistemática: MCID 10 pontos)',
   'utente', 'Hoje')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, ajuda, tipo_resposta, opcoes, min_valor, max_valor, obrigatorio, vetor)
select e.id, v.ordem, v.codigo, v.texto, v.ajuda, 'opcoes', v.opcoes::jsonb, 0, 5, true, 'funcao'
  from public.escalas e
  cross join (values
    (1, 'odi_1', 'Intensidade da dor',
     'Escolhe a frase que melhor descreve a tua dor neste momento.',
     '[{"valor":0,"texto":"Não tenho dor neste momento"},{"valor":1,"texto":"A dor é muito ligeira"},{"valor":2,"texto":"A dor é moderada"},{"valor":3,"texto":"A dor é bastante intensa"},{"valor":4,"texto":"A dor é muito intensa"},{"valor":5,"texto":"A dor é a pior que se pode imaginar"}]'),
    (2, 'odi_2', 'Cuidados pessoais (lavar-se, vestir-se)',
     'Sem ajuda, com que dificuldade te lavas e te vestes?',
     '[{"valor":0,"texto":"Faço-o sem dor adicional"},{"valor":1,"texto":"Faço-o, mas causa dor"},{"valor":2,"texto":"Faço-o devagar e com cuidado, por causa da dor"},{"valor":3,"texto":"Preciso de alguma ajuda, mas faço a maior parte"},{"valor":4,"texto":"Preciso de ajuda para quase tudo"},{"valor":5,"texto":"Não me visto, lavo-me com dificuldade e fico na cama"}]'),
    (3, 'odi_3', 'Levantar pesos',
     'Consegues levantar pesos?',
     '[{"valor":0,"texto":"Levanto pesos sem dor adicional"},{"valor":1,"texto":"Levanto pesos, mas causa dor"},{"valor":2,"texto":"A dor impede-me de levantar pesos do chão, mas consigo se estiverem bem colocados"},{"valor":3,"texto":"A dor impede-me de levantar pesos, mas consigo objetos leves ou médios se estiverem bem colocados"},{"valor":4,"texto":"Só consigo levantar objetos muito leves"},{"valor":5,"texto":"Não consigo levantar nem transportar nada"}]'),
    (4, 'odi_4', 'Andar',
     'Consegues andar?',
     '[{"valor":0,"texto":"Ando sem dor em qualquer distância"},{"valor":1,"texto":"A dor impede-me de andar mais de um quilómetro"},{"valor":2,"texto":"A dor impede-me de andar mais de 500 metros"},{"valor":3,"texto":"A dor impede-me de andar mais de 100 metros"},{"valor":4,"texto":"Só ando com bengala ou muletas"},{"valor":5,"texto":"Estou na cama a maior parte do tempo e arrasto-me até à casa de banho"}]'),
    (5, 'odi_5', 'Estar sentado',
     'Quanto tempo consegues estar sentado?',
     '[{"valor":0,"texto":"Fico sentado o tempo que quiser, em qualquer cadeira"},{"valor":1,"texto":"Só fico sentado na minha cadeira preferida, o tempo que quiser"},{"valor":2,"texto":"A dor impede-me de ficar sentado mais de uma hora"},{"valor":3,"texto":"A dor impede-me de ficar sentado mais de meia hora"},{"valor":4,"texto":"A dor impede-me de ficar sentado mais de 10 minutos"},{"valor":5,"texto":"A dor impede-me de estar sentado"}]'),
    (6, 'odi_6', 'Estar de pé',
     'Quanto tempo consegues estar de pé?',
     '[{"valor":0,"texto":"Fico de pé o tempo que quiser, sem dor adicional"},{"valor":1,"texto":"Fico de pé o tempo que quiser, mas com dor adicional"},{"valor":2,"texto":"A dor impede-me de ficar de pé mais de uma hora"},{"valor":3,"texto":"A dor impede-me de ficar de pé mais de meia hora"},{"valor":4,"texto":"A dor impede-me de ficar de pé mais de 10 minutos"},{"valor":5,"texto":"A dor impede-me de estar de pé"}]'),
    (7, 'odi_7', 'Dormir',
     'O sono é afetado pela dor?',
     '[{"valor":0,"texto":"O sono nunca é afetado pela dor"},{"valor":1,"texto":"O sono é raramente afetado pela dor"},{"valor":2,"texto":"Durmo menos de seis horas por causa da dor"},{"valor":3,"texto":"Durmo menos de quatro horas por causa da dor"},{"valor":4,"texto":"Durmo menos de duas horas por causa da dor"},{"valor":5,"texto":"A dor impede-me de dormir"}]'),
    (8, 'odi_8', 'Vida social',
     'A dor afeta a tua vida social?',
     '[{"valor":0,"texto":"A minha vida social é normal e não me causa mais dor"},{"valor":1,"texto":"A minha vida social é normal, mas aumenta o grau de dor"},{"valor":2,"texto":"A dor limita a minha vida social, mas saio na mesma"},{"valor":3,"texto":"A dor restringe a minha vida social e só saio de casa com menos frequência"},{"valor":4,"texto":"A dor restringe a minha vida social a casa"},{"valor":5,"texto":"Não tenho vida social por causa da dor"}]'),
    (9, 'odi_9', 'Viajar',
     'Consegues viajar?',
     '[{"valor":0,"texto":"Viajo para qualquer lado sem dor adicional"},{"valor":1,"texto":"Viajo para qualquer lado, mas com dor adicional"},{"valor":2,"texto":"A dor é maior, mas consigo fazer viagens de mais de duas horas"},{"valor":3,"texto":"A dor limita-me a viagens de menos de uma hora"},{"valor":4,"texto":"A dor limita-me a viagens curtas e necessárias, de menos de 30 minutos"},{"valor":5,"texto":"A dor impede-me de viajar, exceto para tratamento"}]'),
    (10, 'odi_10', 'Cuidados pessoais e vida social na comunidade',
     'A dor afeta a tua capacidade de tomar conta de ti em casa e fora?',
     '[{"valor":0,"texto":"Tomo conta de mim em casa e fora sem dor adicional"},{"valor":1,"texto":"Tomo conta de mim, mas com dor adicional"},{"valor":2,"texto":"Tomo conta de mim, mas com mais dor e devagar"},{"valor":3,"texto":"Preciso de alguma ajuda, mas faço a maior parte"},{"valor":4,"texto":"Preciso de ajuda na maior parte das tarefas"},{"valor":5,"texto":"Não consigo tomar conta de mim"}]')
  ) as v(ordem, codigo, texto, ajuda, opcoes)
 where e.codigo = 'odi' and e.clinica_id is null
on conflict do nothing;

/* O peso 2 converte a soma de 0-50 no resultado percentual de 0-100 que a
   escala publica. Fazê-lo com o motor de cálculo que já existe evita uma
   função nova — e uma função nova é mais um sítio onde o score se pode
   calcular de duas maneiras diferentes. */
update public.escala_itens i set peso = 2
  from public.escalas e
 where i.escala_id = e.id and e.codigo = 'odi' and e.clinica_id is null;


-- ---------------------------------------------------------------------------
-- 4. QUICKDASH — Incapacidade do membro superior
--
-- Onze itens, cada um de 1 a 5, sobre o que o braço permite fazer. A versão
-- curta do DASH: metade dos itens, a mesma informação clínica, e a diferença
-- importa porque um questionário de 30 itens não é preenchido numa sala de
-- espera.
--
-- PONTUAÇÃO: ((soma / n) - 1) × 25, com n = número de itens respondidos.
-- Cada item de 1 a 5, por isso o valor médio está entre 1 e 5.
--   · valor médio 1 → score 0
--   · valor médio 5 → score 100
-- Ou seja: score = (valor médio - 1) × 25 = soma × (25/n) - 25.
--
-- O peso 25/n por item faz a parte multiplicativa. A subtração do 25 tem de ser
-- feita depois, e é a razão de o QuickDASH precisar de uma expressão no motor de
-- cálculo enquanto o ODI, o KOOS e o Berg não precisam.
--
-- A PRIMEIRA VERSÃO ESTAVA ERRADA e o teste apanhou-o: usava peso 6,25 sem
-- subtrair nada, e dava 68,75 no mínimo e 343,75 no máximo — uma escala que
-- ninguém reconheceria. Um número plausível e falso num relatório para uma
-- seguradora é pior do que não ter a escala, e é exatamente por isso que o
-- teste calcula as duas extremidades em vez de confiar na definição.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica, licenca,
   mcid, mdc, mcid_melhoria, mcid_pior, mcid_fonte,
   modo_administracao, periodo_recordacao)
values
  (null, 'quickdash', 'Questionário de Incapacidade do Braço, Ombro e Mão (versão curta)',
   'QuickDASH', '1.0', 'funcao', 'soma',
   0, 100,
   '[{"max":0,"rotulo":"sem incapacidade","gravidade":"ausente"},
     {"max":15,"rotulo":"incapacidade ligeira","gravidade":"leve"},
     {"max":40,"rotulo":"incapacidade moderada","gravidade":"moderada"},
     {"max":70,"rotulo":"incapacidade grave","gravidade":"grave"},
     {"max":100,"rotulo":"incapacidade muito grave","gravidade":"grave"}]'::jsonb,
   false, array['adulto','senior'], 'mfr',
   'Onze itens sobre dificuldade em usar o braço, ombro ou mão nas atividades do dia a dia, na última semana. Score de 0 (sem incapacidade) a 100 (incapacidade máxima).',
   'Beaton et al. 2005; versão portuguesa validada',
   'Uso livre para avaliação clínica (Institute for Work & Health)',
   8, 8, 8, 8,
   'Franchignoni et al. 2014 (MCID 8 pontos)',
   'utente', 'Na ultima semana')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, ajuda, tipo_resposta, opcoes, min_valor, max_valor, obrigatorio, vetor)
select e.id, v.ordem, v.codigo, v.texto, v.ajuda, 'opcoes', v.opcoes::jsonb, 1, 5, true, 'funcao'
  from public.escalas e
  cross join (values
    (1, 'qd_1', 'Abrir um frasco novo ou apertado',
     'Sem dificuldade (1) a incapaz (5). Responde pensando na última semana.',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (2, 'qd_2', 'Fazer tarefas domésticas pesadas (lavar paredes, esfregar o chão)',
     'Sem dificuldade (1) a incapaz (5).',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (3, 'qd_3', 'Transportar um saco de compras ou uma pasta',
     'Sem dificuldade (1) a incapaz (5).',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (4, 'qd_4', 'Lavar as costas',
     'Sem dificuldade (1) a incapaz (5).',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (5, 'qd_5', 'Usar uma faca para cortar alimentos',
     'Sem dificuldade (1) a incapaz (5).',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (6, 'qd_6', 'Atividades de lazer que exigem algum esforço no braço (jogar às cartas, martelar)',
     'Sem dificuldade (1) a incapaz (5).',
     '[{"valor":1,"texto":"Sem dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz"}]'),
    (7, 'qd_7', 'Quanto é que o problema do braço interferiu com a vida social?',
     'Nada (1) a extremamente (5).',
     '[{"valor":1,"texto":"Nada"},{"valor":2,"texto":"Um pouco"},{"valor":3,"texto":"Moderadamente"},{"valor":4,"texto":"Muito"},{"valor":5,"texto":"Extremamente"}]'),
    (8, 'qd_8', 'Limitação no trabalho ou noutras atividades diárias por causa do braço',
     'Nada limitado (1) a incapaz (5).',
     '[{"valor":1,"texto":"Nada limitado"},{"valor":2,"texto":"Ligeiramente limitado"},{"valor":3,"texto":"Moderadamente limitado"},{"valor":4,"texto":"Muito limitado"},{"valor":5,"texto":"Incapaz"}]'),
    (9, 'qd_9', 'Dor no braço, ombro ou mão',
     'Nenhuma (1) a extrema (5).',
     '[{"valor":1,"texto":"Nenhuma"},{"valor":2,"texto":"Ligeira"},{"valor":3,"texto":"Moderada"},{"valor":4,"texto":"Grave"},{"valor":5,"texto":"Extrema"}]'),
    (10, 'qd_10', 'Formigueiro ou dormência no braço, ombro ou mão',
     'Nenhum (1) a extremo (5).',
     '[{"valor":1,"texto":"Nenhum"},{"valor":2,"texto":"Ligeiro"},{"valor":3,"texto":"Moderado"},{"valor":4,"texto":"Grave"},{"valor":5,"texto":"Extremo"}]'),
    (11, 'qd_11', 'Dificuldade em dormir por causa da dor no braço, ombro ou mão',
     'Nenhuma (1) a extrema (5).',
     '[{"valor":1,"texto":"Nenhuma dificuldade"},{"valor":2,"texto":"Dificuldade ligeira"},{"valor":3,"texto":"Dificuldade moderada"},{"valor":4,"texto":"Dificuldade grave"},{"valor":5,"texto":"Incapaz de dormir"}]')
  ) as v(ordem, codigo, texto, ajuda, opcoes)
 where e.codigo = 'quickdash' and e.clinica_id is null
on conflict do nothing;

/* Pesa cada item por 1: a soma é a soma dos itens, e a expressão faz o resto.
   Deixar o peso a 6,25 e aplicar a expressão contaria a escala duas vezes. */
update public.escala_itens i set peso = 1
  from public.escalas e
 where i.escala_id = e.id and e.codigo = 'quickdash' and e.clinica_id is null;

/* A expressão de cálculo: score = (total / n − 1) × 25.
   Tem de ser escrita AQUI, e não só na migração 0021, porque as migrações
   correm antes dos seeds — a migração escrevia `metodo = 'formula'` e o
   `insert ... on conflict do nothing` acima não a desfazia, mas numa instalação
   já existente o seed não volta a inserir e ficava tudo certo. O que estava
   errado era a ORIGEM: o `values` acima dizia `'soma'`, e é esse o valor que
   uma instalação nova recebe se este update não existir. Foi o que se viu. */
update public.escalas
   set metodo = 'formula',
       expressao_calculo = '(total / n - 1) * 25',
       score_min = 0,
       score_max = 100
 where codigo = 'quickdash' and clinica_id is null;


-- ---------------------------------------------------------------------------
-- 5. KOOS — Lesões e osteoartrose do joelho
--
-- Cinco subescalas: dor, sintomas, função na vida diária, função no desporto e
-- lazer, e qualidade de vida. Cada uma pontua de 0 (pior) a 100 (melhor).
--
-- PORQUE É UMA ESCALA E NÃO CINCO: as cinco subescalas medem o MESMO joelho e
-- são respondidas na mesma consulta. Cinco entradas no catálogo obrigariam o
-- clínico a escolher qual aplicar — e a resposta é sempre «as cinco».
-- `escala_itens.vetor` separa-as por vetor para o relatório, e o score total
-- usa o método 'media' (a média das subescalas é o que a literatura reporta).
--
-- IMPLEMENTAÇÃO: cada item de 0 a 4, invertido — 4 é «sem dificuldade» e conta
-- 4 pontos, 0 é «sempre» e conta 0. O motor de cálculo trata a inversão, e a
-- média dos itens × 25 dá a escala de 0 a 100.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica, licenca,
   mcid, mdc, mcid_melhoria, mcid_pior, mcid_fonte,
   modo_administracao, periodo_recordacao)
values
  (null, 'koos', 'Resultado de Lesões e Osteoartrose do Joelho', 'KOOS', '1.0', 'funcao', 'soma',
   0, 100,
   '[{"max":25,"rotulo":"limitação muito grave","gravidade":"grave"},
     {"max":50,"rotulo":"limitação grave","gravidade":"grave"},
     {"max":75,"rotulo":"limitação moderada","gravidade":"moderada"},
     {"max":90,"rotulo":"limitação ligeira","gravidade":"leve"},
     {"max":100,"rotulo":"sem limitação","gravidade":"ausente"}]'::jsonb,
   false, array['adulto','senior'], 'mfr',
   'Cinco subescalas sobre o joelho, na última semana: dor, sintomas, função na vida diária, função no desporto e lazer, e qualidade de vida. Cada subescala de 0 (pior) a 100 (melhor).',
   'Roos et al. 1998; versão portuguesa validada',
   'Uso livre para avaliação clínica',
   8, 8, 8, 10,
   'Roos & Lohmander 2003 (MCID 8 a 10 pontos, conforme a subescala)',
   'utente', 'Na ultima semana')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, ajuda, tipo_resposta, opcoes, min_valor, max_valor, obrigatorio, vetor)
select e.id, v.ordem, v.codigo, v.texto, v.ajuda, 'opcoes', v.opcoes::jsonb, 0, 4, true, v.vetor
  from public.escalas e
  cross join (values
    (1, 'koos_s1', 'Sintomas: rigidez ou inchaço no joelho', 'Com que frequência nos últimos 7 dias?', 'movimento', '[{"valor":4,"texto":"Nunca"},{"valor":3,"texto":"Raramente"},{"valor":2,"texto":"Às vezes"},{"valor":1,"texto":"Frequentemente"},{"valor":0,"texto":"Sempre"}]'),
    (2, 'koos_s2', 'Sintomas: ouves estalidos ou sentes o joelho a ranger', 'Com que frequência nos últimos 7 dias?', 'movimento', '[{"valor":4,"texto":"Nunca"},{"valor":3,"texto":"Raramente"},{"valor":2,"texto":"Às vezes"},{"valor":1,"texto":"Frequentemente"},{"valor":0,"texto":"Sempre"}]'),
    (3, 'koos_d1', 'Dor: ao torcer ou rodar o joelho', 'Quanta dor nos últimos 7 dias?', 'dor', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (4, 'koos_d2', 'Dor: ao esticar completamente o joelho', 'Quanta dor nos últimos 7 dias?', 'dor', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (5, 'koos_d3', 'Dor: ao subir ou descer escadas', 'Quanta dor nos últimos 7 dias?', 'dor', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (6, 'koos_d4', 'Dor: ao estar sentado ou deitado', 'Quanta dor nos últimos 7 dias?', 'dor', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (7, 'koos_a1', 'Função diária: descer escadas', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (8, 'koos_a2', 'Função diária: subir escadas', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (9, 'koos_a3', 'Função diária: levantar-se da posição sentada', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (10, 'koos_a4', 'Função diária: calçar meias ou collants', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (11, 'koos_a5', 'Função diária: dobrar-se para apanhar algo do chão', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (12, 'koos_sp1', 'Desporto e lazer: agachar-te', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (13, 'koos_sp2', 'Desporto e lazer: correr', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (14, 'koos_sp3', 'Desporto e lazer: saltar', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (15, 'koos_sp4', 'Desporto e lazer: rodar ou torcer o joelho', 'Que dificuldade nos últimos 7 dias?', 'funcao', '[{"valor":4,"texto":"Nenhuma"},{"valor":3,"texto":"Ligeira"},{"valor":2,"texto":"Moderada"},{"valor":1,"texto":"Grave"},{"valor":0,"texto":"Muito grave"}]'),
    (16, 'koos_q1', 'Qualidade de vida: com que frequência tens consciência do joelho',
     'Nos últimos 7 dias.', 'funcao', '[{"valor":4,"texto":"Nunca"},{"valor":3,"texto":"Mensalmente"},{"valor":2,"texto":"Semanalmente"},{"valor":1,"texto":"Diariamente"},{"valor":0,"texto":"Sempre"}]'),
    (17, 'koos_q2', 'Qualidade de vida: modificaste o estilo de vida por causa do joelho',
     'Nos últimos 7 dias.', 'funcao', '[{"valor":4,"texto":"Não modificquei nada"},{"valor":3,"texto":"Modifiquei ligeiramente"},{"valor":2,"texto":"Modifiquei moderadamente"},{"valor":1,"texto":"Modifiquei bastante"},{"valor":0,"texto":"Modifiquei tudo"}]'),
    (18, 'koos_q3', 'Qualidade de vida: quanto te incomoda a falta de confiança no joelho',
     'Nos últimos 7 dias.', 'funcao', '[{"valor":4,"texto":"Nada"},{"valor":3,"texto":"Um pouco"},{"valor":2,"texto":"Moderadamente"},{"valor":1,"texto":"Muito"},{"valor":0,"texto":"Extremamente"}]'),
    (19, 'koos_q4', 'Qualidade de vida: quão difícil é o joelho em geral',
     'Nos últimos 7 dias.', 'funcao', '[{"valor":4,"texto":"Nada difícil"},{"valor":3,"texto":"Um pouco difícil"},{"valor":2,"texto":"Moderadamente difícil"},{"valor":1,"texto":"Muito difícil"},{"valor":0,"texto":"Extremamente difícil"}]')
  ) as v(ordem, codigo, texto, ajuda, vetor, opcoes)
 where e.codigo = 'koos' and e.clinica_id is null
on conflict do nothing;

/* O KOOS usa o método MÉDIA, e é isso que faz a escala publicada: a média dos
   itens (0 a 4, ponderada por 25) dá 0 a 100. Com o método `soma` o resultado
   seria 1900 no máximo — o peso 25 sem divisor.

   Esta distinção entre `soma` e `media` é a diferença entre um instrumento e
   um número inventado, e não se vê olhando para a definição da escala: vê-se
   calculando o score nas extremidades. É o que o teste faz. */
update public.escalas
   set metodo = 'media'
 where codigo = 'koos' and clinica_id is null;

update public.escala_itens i set peso = 25
  from public.escalas e
 where i.escala_id = e.id and e.codigo = 'koos' and e.clinica_id is null;


-- ---------------------------------------------------------------------------
-- 6. BERG — Equilíbrio e risco de queda
--
-- Catorze tarefas de equilíbrio, cada uma de 0 a 4, total 0 a 56. É a escala
-- que decide se um idoso pode ir a casa sozinho — e é por isso que ela e o
-- ponto de corte valem mais do que o score.
--
-- O PONTO DE CORTE É O QUE INTERESSA: 45. Abaixo disso, o risco de queda é
-- substancialmente maior e a alta para casa sem apoio deixa de ser segura.
-- Está na interpretação, e é a razão de este instrumento estar aqui: um número
-- sozinho não decide nada, um número com um limiar decide.
--
-- É a única das quatro que o clínico observa e pontua — `modo_administracao =
-- 'observacao'` —, e por isso é a única que não faz sentido enviar ao portal.
-- ---------------------------------------------------------------------------
insert into public.escalas
  (clinica_id, codigo, nome, nome_curto, versao, dominio, metodo,
   score_min, score_max, interpretacao, baseada_observacao, populacao,
   especialidade, descricao, referencia_bibliografica, licenca,
   mcid, mdc, mcid_melhoria, mcid_pior, mcid_fonte,
   modo_administracao, periodo_recordacao)
values
  (null, 'berg', 'Escala de Equilíbrio de Berg', 'Berg', '1.0', 'funcao', 'soma',
   0, 56,
   '[{"max":20,"rotulo":"equilíbrio muito comprometido — risco de queda elevado, requer apoio","gravidade":"grave"},
     {"max":40,"rotulo":"equilíbrio comprometido — deambulação com apoio","gravidade":"moderada"},
     {"max":44,"rotulo":"risco de queda aumentado — limiar clínico de 45","gravidade":"moderada"},
     {"max":56,"rotulo":"equilíbrio independente e seguro","gravidade":"ausente"}]'::jsonb,
   true, array['adulto','senior'], 'mfr',
   'Catorze tarefas de equilíbrio estático e dinâmico, cada uma de 0 a 4. Total de 0 a 56. O ponto de corte de 45 é o que distingue equilíbrio seguro de risco de queda.',
   'Berg et al. 1992; versão portuguesa validada',
   'Uso livre para avaliação clínica',
   4, 4, 4, 4,
   'Donoghue & Stokes 2009 (MCID 4 pontos); limiar de queda 45 (Berg et al. 1992)',
   'observacao', 'No momento da observacao')
on conflict do nothing;

insert into public.escala_itens
  (escala_id, ordem, codigo, texto, ajuda, tipo_resposta, opcoes, min_valor, max_valor, obrigatorio, vetor)
select e.id, v.ordem, v.codigo, v.texto, v.ajuda, 'opcoes', v.opcoes::jsonb, 0, 4, true, 'funcao'
  from public.escalas e
  cross join (values
    (1, 'berg_1', 'Sentado para de pé', '4 = levanta-se sem usar as mãos e estabiliza; 0 = precisa de ajuda moderada ou máxima.', '[{"valor":4,"texto":"Levanta-se sem usar as mãos e estabiliza sozinho"},{"valor":3,"texto":"Levanta-se sozinho, usando as mãos"},{"valor":2,"texto":"Levanta-se com várias tentativas, usando as mãos"},{"valor":1,"texto":"Precisa de ajuda mínima para se levantar"},{"valor":0,"texto":"Precisa de ajuda moderada ou máxima"}]'),
    (2, 'berg_2', 'De pé sem apoio', '4 = 2 minutos em segurança; 0 = não consegue.', '[{"valor":4,"texto":"Fica de pé 2 minutos em segurança"},{"valor":3,"texto":"Fica de pé 2 minutos com supervisão"},{"valor":2,"texto":"Fica de pé 30 segundos sem apoio"},{"valor":1,"texto":"Precisa de várias tentativas para 30 segundos"},{"valor":0,"texto":"Não consegue ficar de pé sem apoio"}]'),
    (3, 'berg_3', 'Sentado sem apoio, pés no chão', '4 = 2 minutos em segurança.', '[{"valor":4,"texto":"Senta-se 2 minutos em segurança"},{"valor":3,"texto":"Senta-se 2 minutos com supervisão"},{"valor":2,"texto":"Senta-se 30 segundos"},{"valor":1,"texto":"Senta-se 10 segundos"},{"valor":0,"texto":"Não consegue sentar-se sem apoio"}]'),
    (4, 'berg_4', 'De pé para sentado', '4 = senta-se com controlo mínimo das mãos.', '[{"valor":4,"texto":"Senta-se com controlo mínimo das mãos"},{"valor":3,"texto":"Controla a descida com as mãos"},{"valor":2,"texto":"Controla a descida com as pernas contra a cadeira"},{"valor":1,"texto":"Senta-se sozinho mas sem controlo"},{"valor":0,"texto":"Precisa de ajuda para se sentar"}]'),
    (5, 'berg_5', 'Transferências (cadeira para cadeira, cama para cadeira)',
     '4 = transfere-se com apoio mínimo das mãos.', '[{"valor":4,"texto":"Transfere-se com apoio mínimo das mãos"},{"valor":3,"texto":"Transfere-se com apoio das mãos"},{"valor":2,"texto":"Transfere-se com ajuda verbal ou supervisão"},{"valor":1,"texto":"Precisa de uma pessoa para ajudar"},{"valor":0,"texto":"Precisa de duas pessoas ou supervisão constante"}]'),
    (6, 'berg_6', 'De pé com os olhos fechados', '4 = 10 segundos em segurança.', '[{"valor":4,"texto":"Fica de pé 10 segundos em segurança"},{"valor":3,"texto":"Fica de pé 10 segundos com supervisão"},{"valor":2,"texto":"Fica de pé 3 segundos"},{"valor":1,"texto":"Não consegue fechar os olhos 3 segundos mas mantém-se estável"},{"valor":0,"texto":"Precisa de ajuda para não cair"}]'),
    (7, 'berg_7', 'De pé com os pés juntos', '4 = 1 minuto em segurança.', '[{"valor":4,"texto":"Junta os pés e fica 1 minuto em segurança"},{"valor":3,"texto":"Junta os pés e fica 1 minuto com supervisão"},{"valor":2,"texto":"Junta os pés e fica 30 segundos"},{"valor":1,"texto":"Precisa de ajuda para juntar os pés mas fica 15 segundos"},{"valor":0,"texto":"Precisa de ajuda e não consegue manter"}]'),
    (8, 'berg_8', 'Alcançar em frente com o braço estendido, de pé',
     '4 = alcança mais de 25 cm em segurança.', '[{"valor":4,"texto":"Alcança mais de 25 cm em segurança"},{"valor":3,"texto":"Alcança mais de 12 cm em segurança"},{"valor":2,"texto":"Alcança mais de 5 cm em segurança"},{"valor":1,"texto":"Alcança mas precisa de supervisão"},{"valor":0,"texto":"Perde o equilíbrio ao tentar"}]'),
    (9, 'berg_9', 'Apanhar um objeto do chão, de pé',
     '4 = apanha facilmente e em segurança.', '[{"valor":4,"texto":"Apanha facilmente e em segurança"},{"valor":3,"texto":"Apanha mas precisa de supervisão"},{"valor":2,"texto":"Não consegue apanhar mas chega a 2-5 cm do objeto"},{"valor":1,"texto":"Não consegue apanhar e precisa de ajuda"},{"valor":0,"texto":"Não consegue tentar ou precisa de ajuda para não cair"}]'),
    (10, 'berg_10', 'Virar-se para olhar para trás, de pé',
     '4 = olha para trás dos dois lados com boa rotação.', '[{"valor":4,"texto":"Olha para trás dos dois lados e desloca o peso bem"},{"valor":3,"texto":"Olha para trás de um lado apenas"},{"valor":2,"texto":"Vira-se só de lado, sem olhar para trás"},{"valor":1,"texto":"Precisa de supervisão para se virar"},{"valor":0,"texto":"Precisa de ajuda para não cair"}]'),
    (11, 'berg_11', 'Dar uma volta de 360 graus',
     '4 = dá a volta em 4 segundos ou menos, em segurança.', '[{"valor":4,"texto":"Dá a volta em 4 segundos ou menos, em segurança"},{"valor":3,"texto":"Dá a volta em 4 segundos ou menos, de um só lado"},{"valor":2,"texto":"Dá a volta em mais de 4 segundos, devagar"},{"valor":1,"texto":"Precisa de supervisão próxima"},{"valor":0,"texto":"Precisa de ajuda"}]'),
    (12, 'berg_12', 'Colocar os pés alternadamente num degrau, de pé sem apoio',
     '4 = 8 passos em 20 segundos em segurança.', '[{"valor":4,"texto":"8 passos em 20 segundos, em segurança"},{"valor":3,"texto":"8 passos em mais de 20 segundos"},{"valor":2,"texto":"4 passos sem ajuda, com supervisão"},{"valor":1,"texto":"Mais de 2 passos com ajuda mínima"},{"valor":0,"texto":"Precisa de ajuda ou não consegue"}]'),
    (13, 'berg_13', 'De pé sem apoio com um pé à frente do outro',
     '4 = 30 segundos com os pés em tandem.', '[{"valor":4,"texto":"Coloca um pé à frente e fica 30 segundos"},{"valor":3,"texto":"Coloca um pé à frente e fica 30 segundos com supervisão"},{"valor":2,"texto":"Dá um pequeno passo e fica 30 segundos"},{"valor":1,"texto":"Precisa de ajuda para dar o passo mas fica 15 segundos"},{"valor":0,"texto":"Perde o equilíbrio ao dar o passo"}]'),
    (14, 'berg_14', 'De pé sobre uma perna', '4 = 10 segundos sem apoio.', '[{"valor":4,"texto":"Fica 10 segundos sem apoio"},{"valor":3,"texto":"Fica 5 a 10 segundos"},{"valor":2,"texto":"Fica 3 segundos"},{"valor":1,"texto":"Tenta mas não consegue 3 segundos"},{"valor":0,"texto":"Não consegue tentar ou precisa de ajuda"}]')
  ) as v(ordem, codigo, texto, ajuda, opcoes)
 where e.codigo = 'berg' and e.clinica_id is null
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 7. VERIFICAÇÃO
--
-- Falha alto se algum dos quatro não ficou utilizável. Uma escala semeada sem
-- itens produziria um score nulo em silêncio — e um score nulo num relatório
-- para uma seguradora é pior do que não ter a escala.
-- ---------------------------------------------------------------------------
do $$
declare
  v_escala    record;
  v_itens     int;
  v_esperados jsonb := '{"odi":10,"quickdash":11,"koos":19,"berg":14}'::jsonb;
  v_esperado  int;
  v_mcid      int;
  v_metodo    text;
  v_expressao text;
  v_formulas  int;
  v_soma      int;
begin
  for v_escala in
    select id, codigo, nome, mcid, score_max
      from public.escalas
     where clinica_id is null and codigo in ('odi','quickdash','koos','berg')
  loop
    select count(*) into v_itens from public.escala_itens where escala_id = v_escala.id;
    v_esperado := (v_esperados ->> v_escala.codigo)::int;

    if v_itens = 0 then
      raise exception 'A escala % ficou sem itens: produziria um score nulo em silencio.', v_escala.codigo;
    end if;

    if v_itens < v_esperado then
      raise exception 'A escala % tem % itens e devia ter %.', v_escala.codigo, v_itens, v_esperado;
    end if;

    if v_escala.mcid is null then
      raise exception 'A escala % ficou sem MCID: o numero nao diria se o doente melhorou.', v_escala.codigo;
    end if;
  end loop;

  select count(*) into v_mcid
    from public.escalas where clinica_id is null and mcid is not null;
  if v_mcid < 7 then
    raise exception 'So % escalas tem MCID. As tres antigas tambem deviam ter.', v_mcid;
  end if;

  /* --- A EXPRESSÃO DE CÁLCULO DO QUICKDASH -------------------------------- */

  select metodo, expressao_calculo into v_metodo, v_expressao
    from public.escalas where codigo = 'quickdash' and clinica_id is null;

  if v_metodo is distinct from 'formula' then
    raise exception 'O QuickDASH devia usar o metodo formula; usa %. Sem isso o score da 68,75 no minimo.', coalesce(v_metodo, '(sem escala)');
  end if;

  if v_expressao is null or position('total' in v_expressao) = 0 or position('n' in v_expressao) = 0 then
    raise exception 'A expressao do QuickDASH nao usa as variaveis total e n: %', coalesce(v_expressao, '(vazia)');
  end if;

  /* A expressão vive numa tabela, e uma tabela é uma coisa que se edita — e uma
     expressão editada é código a correr. Não se impede, mas exige-se que não
     traga um terminador de instrução.
     
     O `chr(36) || chr(36)` é o cifrão duplo escrito por partes: escrito por
     extenso dentro de um bloco delimitado por cifrões, fecharia o delimitador e
     o resto do ficheiro passava a ser lido como SQL. Já aconteceu. */
  if position(';' in v_expressao) > 0
     or position(chr(36) || chr(36) in v_expressao) > 0 then
    raise exception 'A expressao do QuickDASH tem codigo que nao devia estar la: %', v_expressao;
  end if;

  /* Só UMA escala usa fórmula. As de soma e de média continuam a ser o que são
     — se alguma tivesse passado a fórmula, deixaria de haver um caminho único
     para o score e passaria a haver dois sítios onde ele se calcula. */
  select count(*) into v_formulas from public.escalas where clinica_id is null and metodo = 'formula';
  select count(*) into v_soma from public.escalas where clinica_id is null and metodo in ('soma','media');

  if v_formulas <> 1 then
    raise exception 'Devia haver exatamente UMA escala de formula (QuickDASH); ha %.', v_formulas;
  end if;

  if v_soma < 4 then
    raise exception 'So % escalas de soma ou media. O ODI, o KOOS, o Berg e o Barthel deviam ser uma delas.', v_soma;
  end if;

  /* O SCORE CALCULADO, nas extremidades. É a verificação que teria apanhado o
     peso 6,25 — o score parecia um número e era 343. */
  if clinia.calcular_score_escala(
       (select id from public.escalas where codigo = 'quickdash' and clinica_id is null),
       (select jsonb_object_agg(i.codigo, jsonb_build_object('valor', 1))
          from public.escala_itens i
          join public.escalas e on e.id = i.escala_id
         where e.codigo = 'quickdash' and e.clinica_id is null)
     ) <> 0 then
    raise exception 'O QuickDASH com todas as respostas a 1 devia dar 0.';
  end if;

  if clinia.calcular_score_escala(
       (select id from public.escalas where codigo = 'quickdash' and clinica_id is null),
       (select jsonb_object_agg(i.codigo, jsonb_build_object('valor', 5))
          from public.escala_itens i
          join public.escalas e on e.id = i.escala_id
         where e.codigo = 'quickdash' and e.clinica_id is null)
     ) <> 100 then
    raise exception 'O QuickDASH com todas as respostas a 5 devia dar 100.';
  end if;

  /* Uma escala RESPONDIDA com zeros tem de dar zero, e uma escala SEM respostas
     tem de dar nulo. A versão anterior do motor confundia as duas. */
  if clinia.calcular_score_escala(
       (select id from public.escalas where codigo = 'barthel' and clinica_id is null),
       (select jsonb_object_agg(i.codigo, jsonb_build_object('valor', 0))
          from public.escala_itens i
          join public.escalas e on e.id = i.escala_id
         where e.codigo = 'barthel' and e.clinica_id is null)
     ) is distinct from 0 then
    raise exception 'Um Barthel com todas as respostas a zero tem de dar 0, e nao nulo: e o doente mais dependente possivel.';
  end if;

  if clinia.calcular_score_escala(
       (select id from public.escalas where codigo = 'barthel' and clinica_id is null), '{}'::jsonb
     ) is not null then
    raise exception 'Um Barthel SEM respostas tem de dar nulo, e nao zero.';
  end if;

  /* A especialidade deixa de ser obrigatória para quem nao trata, mas continua
     a ser para quem trata. Verifica-se nos dados, nao na definicao. */
  if exists (
    select 1 from public.perfis
     where perfil in ('fisiatra','fisioterapeuta','osteopata','terapeuta_ocupacional',
                      'terapeuta_da_fala','psicologo','enfermeiro')
       and especialidade is null
  ) then
    raise exception 'Ha perfis clinicos sem especialidade: a restricao nao ficou a funcionar.';
  end if;

  raise notice 'PROMs: ODI, QuickDASH, KOOS e Berg semeados, com MCID e limiares.';
end $$;


-- ----------------------------------------------------------------------------
-- 0008_dicionario_endoscopia.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- clinia.ai · seed 0008 — DICIONÁRIO DE ENDOSCOPIA
--
-- FICHEIRO GERADO. NÃO EDITAR À MÃO: as alterações perdem-se na geração
-- seguinte. A fonte é:
--
--     ENSAIOEndoscopIA/02-Dicionario/gastro.json
--
-- e regenera-se com:
--
--     node ENSAIOEndoscopIA/03-Gerador/gerar-seed-dicionario.mjs
--
-- Versão do dicionário: 0.1.0 (2026-10-15)
-- Estado: rascunho para revisão clínica
-- Revisor: Dr. Hugo Amaral
--
-- As tabelas são as da migração 0032. Este ficheiro só insere dados.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PROCEDIMENTOS
-- ---------------------------------------------------------------------------
insert into public.endo_procedimentos (codigo, nome, modulo, ordem, obrigatorios, nota_obrigatorios)
values
  ('eda', 'Endoscopia digestiva alta', 'gastro', 10, '["indicacao","preparacao_jejum","sedacao","ate_onde_se_chegou","marcos_fotografados","amostras","complicacoes","duracao"]', null),
  ('colono', 'Colonoscopia', 'gastro', 20, '["indicacao","preparacao_intestinal","sedacao","intubacao_cecal","ate_onde_se_chegou","marcos_fotografados","tempo_insercao","tempo_retirada","polipectomia_adequada","amostras","complicacoes","recomendacao_seguimento"]', 'A qualidade da preparação e o tempo de retirada são obrigatórios em TODA a colonoscopia — é o que permite ler a taxa de deteção de adenomas sem a confundir com má preparação.'),
  ('cpre', 'Colangiopancreatografia retrógrada endoscópica (CPRE)', 'gastro', 30, '["indicacao","canulacao","sedacao","amostras","complicacoes","duracao","fluoroscopia"]', null)
on conflict (codigo) do update set
  nome = excluded.nome,
  ordem = excluded.ordem,
  obrigatorios = excluded.obrigatorios,
  nota_obrigatorios = excluded.nota_obrigatorios,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 2. LOCALIZACOES (30)
-- ---------------------------------------------------------------------------
insert into public.endo_localizacoes (codigo, rotulo, nota, ordem)
values
  ('esofago_proximal', 'Esófago proximal', null, 10),
  ('esofago_medio', 'Esófago médio', null, 20),
  ('esofago_distal', 'Esófago distal', null, 30),
  ('linha_z', 'Linha Z', null, 40),
  ('cardia', 'Cárdia', null, 50),
  ('fundo', 'Fundo gástrico', 'Observado em retroversão', 60),
  ('corpo_pequena_curvatura', 'Corpo — pequena curvatura', null, 70),
  ('corpo_grande_curvatura', 'Corpo — grande curvatura', null, 80),
  ('incisura', 'Incisura angularis', null, 90),
  ('antro', 'Antro', null, 100),
  ('piloro', 'Piloro', null, 110),
  ('bulbo', 'Bulbo duodenal', null, 120),
  ('d2', 'Segunda porção duodenal', null, 130),
  ('papila', 'Papila major', null, 140),
  ('reto_baixo', 'Reto baixo', '2 cm acima da linha anal', 150),
  ('reto_medio', 'Reto médio', null, 160),
  ('reto_superior', 'Reto superior', null, 170),
  ('sigmoide', 'Sigmoide', null, 180),
  ('descendente', 'Cólon descendente', null, 190),
  ('angulo_esplenico', 'Ângulo esplénico', null, 200),
  ('transverso', 'Cólon transverso', null, 210),
  ('angulo_hepatico', 'Ângulo hepático', null, 220),
  ('ascendente', 'Cólon ascendente', null, 230),
  ('cego', 'Cego', null, 240),
  ('valvula_ileocecal', 'Válvula ileocecal', null, 250),
  ('orificio_apendicular', 'Orifício apendicular', null, 260),
  ('ileo_terminal', 'Íleo terminal', 'Quando indicado', 270),
  ('via_biliar', 'Via biliar principal', null, 280),
  ('via_pancreatica', 'Via pancreática', null, 290),
  ('vesicula', 'Vesícula e cístico', null, 300)
on conflict (codigo) do update set
  rotulo = excluded.rotulo, nota = excluded.nota, ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 3. ACHADOS (28)
-- ---------------------------------------------------------------------------
insert into public.endo_achados (codigo, rotulo, ordem)
values
  ('normal', 'Sem alterações', 10),
  ('eritema', 'Eritema', 20),
  ('erosao', 'Erosão', 30),
  ('ulcera', 'Úlcera', 40),
  ('nodularidade', 'Nodularidade', 50),
  ('pregas_espessadas', 'Pregas espessadas', 60),
  ('atrofia_mucosa', 'Atrofia da mucosa', 70),
  ('metaplasia_intestinal', 'Metaplasia intestinal', 80),
  ('lesao_exofitica', 'Lesão exofítica ou vegetante', 90),
  ('estenose', 'Estenose', 100),
  ('varizes', 'Varizes', 110),
  ('lagoa_gastrica', 'Lagoa gástrica (conteúdo)', 120),
  ('barrett_suspeito', 'Suspeita de esófago de Barrett', 130),
  ('diverticulo', 'Divertículo', 140),
  ('outro', 'Outro achado (texto livre)', 150),
  ('polipo', 'Pólipo ou lesão protrusa', 160),
  ('lesao_plana', 'Lesão plana ou deprimida', 170),
  ('afias', 'Úlceras aftoides', 180),
  ('perda_vascular', 'Perda do padrão vascular', 190),
  ('sangramento_espontaneo', 'Sangramento espontâneo', 200),
  ('mucosa_friavel', 'Mucosa friável', 210),
  ('massa', 'Massa ou lesão estenosante suspeita', 220),
  ('calculo_coledoco', 'Cálculo na via biliar', 230),
  ('dilatacao_via_biliar', 'Dilatação da via biliar', 240),
  ('estenose_biliar', 'Estenose biliar', 250),
  ('fistula', 'Fístula biliar', 260),
  ('prostese_previa', 'Prótese biliar prévia', 270),
  ('neoplasia_suspeita', 'Suspeita de neoplasia', 280)
on conflict (codigo) do update set
  rotulo = excluded.rotulo, ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 4. INTERVENCOES (16)
-- ---------------------------------------------------------------------------
insert into public.endo_intervencoes (codigo, rotulo, ordem)
values
  ('polipectomia_fria', 'Polipectomia com ansa fria', 10),
  ('polipectomia_quente', 'Polipectomia com ansa quente', 20),
  ('emr', 'Resseção mucosa endoscópica (EMR)', 30),
  ('esd', 'Disseção submucosa endoscópica (ESD)', 40),
  ('biopsia_fria', 'Biópsia com pinça', 50),
  ('hemostase_injecao', 'Hemostase por injeção', 60),
  ('hemostase_mecanica', 'Hemostase mecânica (clips)', 70),
  ('hemostase_termica', 'Hemostase térmica', 80),
  ('dilatacao', 'Dilatação', 90),
  ('protese', 'Colocação de prótese', 100),
  ('tatuagem', 'Tatuagem com carvão', 110),
  ('nenhuma', 'Sem intervenção', 120),
  ('esfincterotomia', 'Esfincterotomia', 130),
  ('extracao_calculo', 'Extração de cálculo', 140),
  ('prostese_biliar', 'Colocação de prótese biliar', 150),
  ('dilatacao_biliar', 'Dilatação biliar', 160)
on conflict (codigo) do update set
  rotulo = excluded.rotulo, ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 5. SEGMENTOS (3) — a Boston pontua por segmento
-- ---------------------------------------------------------------------------
insert into public.endo_segmentos (codigo, rotulo, ordem)
values
  ('direito', 'Cólon direito (cego e ascendente)', 10),
  ('transverso', 'Cólon transverso', 20),
  ('esquerdo', 'Cólon esquerdo (descendente, sigmoide e reto)', 30)
on conflict (codigo) do update set
  rotulo = excluded.rotulo, ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 6. CLASSIFICACOES (12)
--
-- O `tipo` decide onde os valores vivem, e as duas tabelas estao separadas
-- de proposito: uma categorica nunca produz um numero. Ver a migracao 0032.
-- ---------------------------------------------------------------------------
insert into public.endo_classificacoes
  (codigo, nome, tipo, dominio, versao, escala_por, total_min, total_max, conferir, nota)
values
  ('boston', 'Escala de Boston (BBPS)', 'numerico', 'preparação intestinal', 'Lai 2009', 'segmento', 0, 9, true, 'Somar os três segmentos. Um total adequado pode esconder um segmento mal preparado — vale a pena mostrar o detalhe por segmento, não só a soma.'),
  ('los_angeles', 'Classificação de Los Angeles', 'categorico', 'esofagite de refluxo', 'Los Angeles', null, null, null, false, 'Estenoses, úlceras e Barrett registam-se em campos separados, não dentro do grau.'),
  ('praga_cm', 'Critérios de Praga C&M', 'numerico', 'esófago de Barrett', 'Sharma 2006', 'global', null, null, true, 'A concordância entre examinadores é de 1 a 2 cm. O sistema deve aceitar essa margem em vez de a tratar como erro. Segmentos com menos de 1 cm não são aplicáveis.'),
  ('forrest', 'Classificação de Forrest', 'categorico', 'hemorragia digestiva por úlcera', 'Forrest 1974', null, null, null, true, null),
  ('paris', 'Classificação de Paris', 'categorico', 'morfologia de lesões superficiais', 'Paris 2002, atualização 2005', null, null, null, false, 'As formas mistas são frequentes e registam-se combinadas. Invasão submucosa por tipo, para contexto clínico: 0-Ip 5%, 0-Is 34%, 0-IIa 4%, 0-IIb 0%, 0-IIc 61%.'),
  ('nice', 'Classificação NICE', 'categorico', 'caracterização ótica de pólipos colorretais', 'NICE (Hayers 2011)', null, null, null, false, null),
  ('jnet', 'Classificação JNET', 'categorico', 'caracterização ótica de pólipos colorretais', 'JNET 2016', null, null, null, true, 'O tipo 2B é o ponto fraco declarado da classificação, com sensibilidade de 44,9% a 53,8% mesmo entre experientes. Não deve ser usado isoladamente para decidir conduta.'),
  ('viena', 'Classificação de Viena (revista)', 'categorico', 'correlação endoscopia-histologia', 'Viena revista (Schlemper 2000)', null, null, null, true, null),
  ('uceis', 'UCEIS', 'numerico', 'atividade endoscópica na colite ulcerosa', 'Travis 2012', 'global', 0, 8, false, null),
  ('rutgeerts', 'Classificação de Rutgeerts', 'categorico', 'recidiva pós-cirúrgica na doença de Crohn', 'Rutgeerts 1990, com modificação i2a/i2b', null, null, null, false, null),
  ('kyoto', 'Pontuação de Kyoto', 'categorico', 'gastrite', 'Kyoto 2014', null, null, null, true, null),
  ('clavien_dindo', 'Classificação de Clavien-Dindo', 'categorico', 'gravidade de complicações', 'Dindo 2004', null, null, null, true, null)
on conflict (codigo) do update set
  nome = excluded.nome, tipo = excluded.tipo, dominio = excluded.dominio,
  versao = excluded.versao, escala_por = excluded.escala_por,
  total_min = excluded.total_min, total_max = excluded.total_max,
  conferir = excluded.conferir, nota = excluded.nota;

-- ---------------------------------------------------------------------------
-- 7. VALORES CATEGORICOS (45)
--
-- Esta tabela NAO TEM COLUNA NUMERICA. E isso que impede um codigo categorico
-- de virar um numero num relatorio.
-- ---------------------------------------------------------------------------
insert into public.endo_classificacao_valores (classificacao, codigo, rotulo, nota, ordem)
values
  ('los_angeles', 'ausente', 'Não presente (sem quebras)', null, 10),
  ('los_angeles', 'A', 'Uma ou mais quebras confinadas às pregas, cada ≤ 5 mm', null, 20),
  ('los_angeles', 'B', 'Quebras > 5 mm, não contínuas entre os topos de duas pregas', null, 30),
  ('los_angeles', 'C', 'Quebras contínuas entre os topos de ≥ 2 pregas, < 75% da circunferência', null, 40),
  ('los_angeles', 'D', 'Quebras ≥ 75% da circunferência', null, 50),
  ('forrest', 'Ia', 'Hemorragia em jato', null, 10),
  ('forrest', 'Ib', 'Hemorragia em baba', null, 20),
  ('forrest', 'IIa', 'Vaso visível não hemorrágico', null, 30),
  ('forrest', 'IIb', 'Coágulo aderente', null, 40),
  ('forrest', 'IIc', 'Mancha plana pigmentada', null, 50),
  ('forrest', 'III', 'Base limpa', null, 60),
  ('paris', '0-Ip', 'Protrusa pedunculada', null, 10),
  ('paris', '0-Isp', 'Protrusa semipedunculada', null, 20),
  ('paris', '0-Is', 'Protrusa séssil', null, 30),
  ('paris', '0-IIa', 'Elevação plana da mucosa', null, 40),
  ('paris', '0-IIb', 'Alteração mucosa plana', null, 50),
  ('paris', '0-IIc', 'Depressão mucosa ≤ 1,2 mm', null, 60),
  ('paris', '0-III', 'Depressão mucosa > 1,2 mm', null, 70),
  ('paris', 'misto', 'Forma mista', 'Registar a combinação, por exemplo 0-IIa+Is', 80),
  ('nice', '1', 'Cor semelhante à mucosa; vasos em rede ou ausentes', null, 10),
  ('nice', '2', 'Tonalidade acastanhada; vasos castanhos a rodear estruturas brancas', null, 20),
  ('nice', '3', 'Aspeto escuro; vasos desrompidos ou ausentes; superfície irregular', null, 30),
  ('jnet', '1', 'Vasos invisíveis; superfície com pontos regulares — hiperplásico ou serrado séssil', null, 10),
  ('jnet', '2A', 'Calibre e distribuição regulares — neoplasia intramucosa de baixo grau', null, 20),
  ('jnet', '2B', 'Calibre variável, distribuição irregular — alto grau', null, 30),
  ('jnet', '3', 'Vasos espessos interrompidos; áreas amorfas — carcinoma com invasão profunda', null, 40),
  ('viena', '1', 'Negativo para neoplasia', null, 10),
  ('viena', '2', 'Indefinido para neoplasia', null, 20),
  ('viena', '3', 'Neoplasia não invasiva de baixo grau', null, 30),
  ('viena', '4', 'Neoplasia não invasiva de alto grau', null, 40),
  ('viena', '5', 'Neoplasia invasiva', null, 50),
  ('rutgeerts', 'i0', 'Sem lesões no íleo distal', null, 10),
  ('rutgeerts', 'i1', 'Menos de 5 lesões aftoides no íleo distal', null, 20),
  ('rutgeerts', 'i2', 'Mais de 5 aftas com mucosa normal entre elas, ou lesões maiores em salto, ou lesões confinadas à anastomose', null, 30),
  ('rutgeerts', 'i2a', 'Lesões confinadas à anastomose (modificação)', null, 40),
  ('rutgeerts', 'i2b', 'Mais de 5 úlceras aftoides ou lesões maiores com mucosa normal entre elas, no íleo neoterminal (modificação)', null, 50),
  ('rutgeerts', 'i3', 'Ileíte aftoide difusa com mucosa difusamente inflamada', null, 60),
  ('rutgeerts', 'i4', 'Inflamação difusa com úlceras grandes, nódulos ou cobblestone, ou estenose', null, 70),
  ('clavien_dindo', 'I', 'Grau I', null, 10),
  ('clavien_dindo', 'II', 'Grau II', null, 20),
  ('clavien_dindo', 'IIIa', 'Grau IIIa — intervenção sem anestesia geral', null, 30),
  ('clavien_dindo', 'IIIb', 'Grau IIIb — intervenção com anestesia geral', null, 40),
  ('clavien_dindo', 'IVa', 'Grau IVa — disfunção de um órgão', null, 50),
  ('clavien_dindo', 'IVb', 'Grau IVb — disfunção multiorgânica', null, 60),
  ('clavien_dindo', 'V', 'Grau V — morte', null, 70)
on conflict (classificacao, codigo) do update set
  rotulo = excluded.rotulo, nota = excluded.nota, ordem = excluded.ordem;

-- ---------------------------------------------------------------------------
-- 8. ESCALAS NUMERICAS (4)
--
-- Esta tabela NAO TEM COLUNA DE CODIGO DE CATEGORIA. E o espelho da anterior.
-- ---------------------------------------------------------------------------
insert into public.endo_classificacao_escala (classificacao, valor, rotulo, nota)
values
  ('boston', 0, 'Cólon não preparado, mucosa não visualizável', null),
  ('boston', 1, 'Parte da mucosa visualizável; resíduos ou líquido opaco impedem a visão', null),
  ('boston', 2, 'Resíduos mínimos, aspiáveis; boa visualização', null),
  ('boston', 3, 'Toda a mucosa visualizada, sem resíduo sólido nem líquido opaco', null)
on conflict (classificacao, valor) do update set
  rotulo = excluded.rotulo, nota = excluded.nota;

-- ---------------------------------------------------------------------------
-- 9. O QUE SERVE QUE PROCEDIMENTO
-- ---------------------------------------------------------------------------
-- eda — Endoscopia digestiva alta
insert into public.endo_procedimento_localizacoes (procedimento, localizacao, marco, ordem)
values
  ('eda', 'esofago_proximal', true, 10),
  ('eda', 'esofago_medio', false, 20),
  ('eda', 'esofago_distal', true, 30),
  ('eda', 'linha_z', true, 40),
  ('eda', 'cardia', true, 50),
  ('eda', 'fundo', true, 60),
  ('eda', 'corpo_pequena_curvatura', true, 70),
  ('eda', 'corpo_grande_curvatura', true, 80),
  ('eda', 'incisura', true, 90),
  ('eda', 'antro', true, 100),
  ('eda', 'piloro', false, 110),
  ('eda', 'bulbo', true, 120),
  ('eda', 'd2', true, 130),
  ('eda', 'papila', false, 140)
on conflict (procedimento, localizacao) do update set marco = excluded.marco, ordem = excluded.ordem;

insert into public.endo_procedimento_achados (procedimento, achado, ordem)
values
  ('eda', 'normal', 10),
  ('eda', 'eritema', 20),
  ('eda', 'erosao', 30),
  ('eda', 'ulcera', 40),
  ('eda', 'nodularidade', 50),
  ('eda', 'pregas_espessadas', 60),
  ('eda', 'atrofia_mucosa', 70),
  ('eda', 'metaplasia_intestinal', 80),
  ('eda', 'lesao_exofitica', 90),
  ('eda', 'estenose', 100),
  ('eda', 'varizes', 110),
  ('eda', 'lagoa_gastrica', 120),
  ('eda', 'barrett_suspeito', 130),
  ('eda', 'diverticulo', 140),
  ('eda', 'outro', 150)
on conflict (procedimento, achado) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_classificacoes (procedimento, classificacao, ordem)
values
  ('eda', 'los_angeles', 10),
  ('eda', 'praga_cm', 20),
  ('eda', 'kyoto', 30),
  ('eda', 'forrest', 40)
on conflict (procedimento, classificacao) do update set ordem = excluded.ordem;


-- colono — Colonoscopia
insert into public.endo_procedimento_localizacoes (procedimento, localizacao, marco, ordem)
values
  ('colono', 'reto_baixo', true, 10),
  ('colono', 'reto_medio', false, 20),
  ('colono', 'reto_superior', false, 30),
  ('colono', 'sigmoide', true, 40),
  ('colono', 'descendente', true, 50),
  ('colono', 'angulo_esplenico', false, 60),
  ('colono', 'transverso', true, 70),
  ('colono', 'angulo_hepatico', false, 80),
  ('colono', 'ascendente', true, 90),
  ('colono', 'cego', true, 100),
  ('colono', 'valvula_ileocecal', true, 110),
  ('colono', 'orificio_apendicular', true, 120),
  ('colono', 'ileo_terminal', false, 130)
on conflict (procedimento, localizacao) do update set marco = excluded.marco, ordem = excluded.ordem;

insert into public.endo_procedimento_achados (procedimento, achado, ordem)
values
  ('colono', 'normal', 10),
  ('colono', 'polipo', 20),
  ('colono', 'lesao_plana', 30),
  ('colono', 'eritema', 40),
  ('colono', 'erosao', 50),
  ('colono', 'ulcera', 60),
  ('colono', 'afias', 70),
  ('colono', 'perda_vascular', 80),
  ('colono', 'sangramento_espontaneo', 90),
  ('colono', 'mucosa_friavel', 100),
  ('colono', 'estenose', 110),
  ('colono', 'diverticulo', 120),
  ('colono', 'massa', 130),
  ('colono', 'outro', 140)
on conflict (procedimento, achado) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_intervencoes (procedimento, intervencao, ordem)
values
  ('colono', 'polipectomia_fria', 10),
  ('colono', 'polipectomia_quente', 20),
  ('colono', 'emr', 30),
  ('colono', 'esd', 40),
  ('colono', 'biopsia_fria', 50),
  ('colono', 'hemostase_injecao', 60),
  ('colono', 'hemostase_mecanica', 70),
  ('colono', 'hemostase_termica', 80),
  ('colono', 'dilatacao', 90),
  ('colono', 'protese', 100),
  ('colono', 'tatuagem', 110),
  ('colono', 'nenhuma', 120)
on conflict (procedimento, intervencao) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_classificacoes (procedimento, classificacao, ordem)
values
  ('colono', 'boston', 10),
  ('colono', 'paris', 20),
  ('colono', 'nice', 30),
  ('colono', 'jnet', 40),
  ('colono', 'viena', 50),
  ('colono', 'uceis', 60),
  ('colono', 'rutgeerts', 70)
on conflict (procedimento, classificacao) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_segmentos (procedimento, segmento, ordem)
values
  ('colono', 'direito', 10),
  ('colono', 'transverso', 20),
  ('colono', 'esquerdo', 30)
on conflict (procedimento, segmento) do update set ordem = excluded.ordem;


-- cpre — Colangiopancreatografia retrógrada endoscópica (CPRE)
insert into public.endo_procedimento_localizacoes (procedimento, localizacao, marco, ordem)
values
  ('cpre', 'papila', false, 10),
  ('cpre', 'via_biliar', false, 20),
  ('cpre', 'via_pancreatica', false, 30),
  ('cpre', 'vesicula', false, 40)
on conflict (procedimento, localizacao) do update set marco = excluded.marco, ordem = excluded.ordem;

insert into public.endo_procedimento_achados (procedimento, achado, ordem)
values
  ('cpre', 'calculo_coledoco', 10),
  ('cpre', 'dilatacao_via_biliar', 20),
  ('cpre', 'estenose_biliar', 30),
  ('cpre', 'fistula', 40),
  ('cpre', 'prostese_previa', 50),
  ('cpre', 'neoplasia_suspeita', 60),
  ('cpre', 'normal', 70)
on conflict (procedimento, achado) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_intervencoes (procedimento, intervencao, ordem)
values
  ('cpre', 'esfincterotomia', 10),
  ('cpre', 'extracao_calculo', 20),
  ('cpre', 'prostese_biliar', 30),
  ('cpre', 'dilatacao_biliar', 40),
  ('cpre', 'nenhuma', 50)
on conflict (procedimento, intervencao) do update set ordem = excluded.ordem;

insert into public.endo_procedimento_classificacoes (procedimento, classificacao, ordem)
values
  ('cpre', 'clavien_dindo', 10)
on conflict (procedimento, classificacao) do update set ordem = excluded.ordem;


-- ============================================================================
-- PARTE 3 — A CLÍNICA E O ADMINISTRADOR
-- ============================================================================

do $$
declare
  -- Valores preenchidos pelo gerador. Os marcadores são substituídos por
  -- texto simples, sem regex: um regex sobre estas linhas é frágil ao
  -- alinhamento das colunas e já falhou uma vez.
  v_uid     uuid := '7da45b31-2f88-4628-be59-e68262854c12';
  v_email   text := 'support@clinia.live';
  /* O nome da clínica vem de fora — cada cliente tem o seu. */
  v_clinica_nome text := 'RehAI — ambiente de teste';
  v_clinica uuid;
  v_ok      boolean;
  /* Quantas regras de visibilidade a clínica ficou a ter. Quem as cria é o
     gatilho de 'clinicas' (migração 0019); aqui só se confirma que existem. */
  v_visibilidade integer;
begin
  if not exists (select 1 from auth.users u where u.id = v_uid) then
    raise exception
      'O UID % não existe em auth.users. Cria o utilizador em Authentication > Users (com Auto Confirm User) antes de correr isto.',
      v_uid;
  end if;

  select c.id into v_clinica from public.clinicas c order by c.created_at limit 1;

  if v_clinica is null then
    /* O nome vem do parâmetro, e o nome_curto é o nome truncado — serve para o
       cabeçalho e para os documentos, onde um nome comprido não cabe.
       (Sem crases nesta frase: este comentário vive DENTRO de um template
       literal do JavaScript, e uma crase aqui fecha-o. Aconteceu — o gerador
       deixou de compilar com «missing ) after argument list», que não aponta
       para a crase.)

       O PRODUTO E A ESPECIALIDADE VÊM DA CONFIGURAÇÃO. Estavam fixos em mfr e
       isso fazia toda a instalação nascer como clínica de reabilitação — mesmo a
       de endoscopia. Ver a nota no topo do gerador.
       (Sem crases: este comentário vive dentro de um template literal, e uma
       crase aqui fecha-o. Foi assim que este ficheiro deixou de compilar.) */
    insert into public.clinicas (nome, nome_curto, pais, regiao_dados, produto, especialidades)
    values (v_clinica_nome, left(v_clinica_nome, 24), 'PT', 'eu-west-1',
            'rehab'::public.produto,
            array['mfr']::public.especialidade[])
    returning id into v_clinica;
    raise notice 'Clínica criada: % (%) — produto %', v_clinica_nome, v_clinica, 'rehab';
  else
    /* A CLÍNICA JÁ EXISTE: o produto é CORRIGIDO, e não ignorado.
       Sem isto, uma base de dados criada antes desta correção ficava para sempre
       com produto = rehab — e o menu errado. O ficheiro de instalação é para
       poder correr duas vezes, e a segunda vez tem de deixar a clínica com o
       produto que o ficheiro diz. */
    update public.clinicas set produto = 'rehab'::public.produto
     where id = v_clinica and produto is distinct from 'rehab'::public.produto;
    raise notice 'Clínica já existia: % — produto acertado para rehab', v_clinica;
  end if;

  /* OS MÓDULOS DO PRODUTO, LIGADOS A ESTA CLÍNICA.
     Um produto sem os seus módulos ligados não mostra ecrã nenhum: o menu
     depende de clinica_modulos. A migração 0013b liga o MFR a todas as
     clínicas; aqui liga-se o que falta, e os módulos do produto ficam
     DISPONÍVEIS — são o que esta instalação existe para servir.
     (Sem crases, pela mesma razão de cima.) */
  insert into public.clinica_modulos (clinica_id, modulo_codigo, ativo)
  select v_clinica, m.codigo, true
    from public.modulos m
   where m.produto = 'rehab'::public.produto
  on conflict (clinica_id, modulo_codigo) do update set ativo = true;

  update public.modulos set disponivel = true
   where produto = 'rehab'::public.produto;

  insert into public.perfis (id, clinica_id, nome, email, perfil, especialidade, ativo)
  values (v_uid, v_clinica, 'Administrador', v_email, 'administrador', 'mfr', true)
  on conflict (id) do update
     set clinica_id = excluded.clinica_id,
         email      = excluded.email,
         perfil     = excluded.perfil,
         especialidade = excluded.especialidade,
         ativo      = true;

  /* ---------------------------------------------------------------------
     A VISIBILIDADE DOS ECRÃS — VERIFICAR, NÃO SEMEAR OUTRA VEZ
     ---------------------------------------------------------------------
     Quem semeia as regras por omissão é o gatilho 'after insert' de 'clinicas',
     criado na migração 0019: 'clinia.semear_visibilidade_da_clinica()'.

     Escrevi aqui um semeador a mais antes de descobrir isso — e o teste NÃO
     apanhou a diferença, porque os dois produzem as mesmas 86 linhas. Aprendi-o
     ao tentar provar que o teste apanhava o defeito: removi o meu bloco e o
     teste continuou verde, porque o gatilho fazia o trabalho.

     Um semeador duplicado não é inofensivo: são dois sítios com a mesma regra de
     negócio, e o dia em que um mudar o outro fica a mentir. Fica só a
     VERIFICAÇÃO — que é o que faltava a sério.

     Sem regras de visibilidade, a vista 'vw_ecras_do_perfil' devolve vazio e o
     menu do administrador fica sem «Episódios», «Planos» e «Sessões». É uma
     falha silenciosa: nada rebenta, o menu apenas aparece incompleto.
     --------------------------------------------------------------------- */
  select count(*) into v_visibilidade
    from public.perfil_visibilidade
   where clinica_id = v_clinica and visivel;

  if v_visibilidade = 0 then
    raise exception
      'A clinica % ficou sem regras de visibilidade. O menu apareceria sem Episodios, Planos nem Sessoes. Verifica se o gatilho t_semear_visibilidade existe em public.clinicas (migracao 0019).',
      v_clinica;
  end if;

  select exists (
    select 1 from public.perfis p
      join public.clinicas c on c.id = p.clinica_id
     where p.id = v_uid and p.ativo and p.perfil in ('administrador','gestao')
  ) into v_ok;

  if not v_ok then
    raise exception 'O perfil do administrador não ficou utilizável.';
  end if;

  raise notice 'Administrador ligado: % (%)', v_email, v_uid;
  raise notice 'Visibilidade dos ecrãs: % regras atribuídas.', v_visibilidade;
end $$;

commit;

-- ============================================================================
-- VERIFICAÇÃO — o que ficou criado
-- ============================================================================
do $$
declare
  v_tabelas  integer;
  v_vistas   integer;
  v_politicas integer;
  v_sem_rls  text[];
  v_clinicas integer;
  v_admin    text;
begin
  select count(*) into v_tabelas
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r';

  select count(*) into v_vistas
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v';

  select count(*) into v_politicas from pg_policies where schemaname = 'public';

  select coalesce(array_agg(c.relname), '{}') into v_sem_rls
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

  select count(*) into v_clinicas from public.clinicas;

  raise notice '---------------------------------------------';
  raise notice 'INSTALAÇÃO CONCLUÍDA';
  raise notice '  Tabelas    : %', v_tabelas;
  raise notice '  Vistas     : %', v_vistas;
  raise notice '  Políticas  : %', v_politicas;
  raise notice '  Clínicas   : %', v_clinicas;
  if array_length(v_sem_rls, 1) > 0 then
    raise warning '  ATENÇÃO: tabelas sem RLS: %', array_to_string(v_sem_rls, ', ');
  else
    raise notice '  RLS        : ativo em todas as tabelas';
  end if;
  raise notice '---------------------------------------------';
  -- Ler o email do administrador da própria tabela: v_email pertence ao bloco
  -- anterior e cada bloco DO tem o seu escopo. Uma referência atravessada dá
  -- "column v_email does not exist" — erro que só aparece no fim da instalação,
  -- depois de tudo criado, o que é a pior altura possível para falhar.
  select p.email into v_admin from public.perfis p where p.perfil = 'administrador' order by p.created_at limit 1;
  raise notice 'Próximo passo: abrir a aplicação e entrar com %', coalesce(v_admin, '(sem administrador)');
end $$;

-- ============================================================================
-- PARTE 4 — VERIFICAÇÃO FINAL
-- ============================================================================
-- Contar tabelas não é verificar uma instalação.
--
-- Este bloco confirma as coisas que, quando falham, NÃO DÃO ERRO — e por isso
-- só se descobrem quando alguém tenta usar o programa:
--
--   · o administrador ligado existe MESMO em auth.users?
--   · há alguma tabela de cliente sem RLS?
--   · há alguma vista que contorna o RLS?
--   · as alergias e a medicação ficaram criadas?
--
-- Cada problema é dito com o que fazer a seguir. Um aviso que não diz o que
-- fazer é ruído, e o ruído ensina a ignorar avisos.
-- ============================================================================
do $$
declare
  v_admin_uid   uuid;
  v_admin_email text;
  v_existe      boolean;
  v_ativos      integer;
  v_sem_rls     text[];
  v_vistas_maus text[];
  v_alergias    boolean;
  v_medicacao   boolean;
  v_ecra_codigo boolean;
  v_problemas   integer := 0;
begin
  raise notice '';
  raise notice '=============================================';
  raise notice ' VERIFICACAO DA INSTALACAO';
  raise notice '=============================================';

  /* -------------------------------------------------------------------------
     1. O ADMINISTRADOR — a verificação que mais falta fazia
     -------------------------------------------------------------------------
     O auth.users é do Supabase. O SQL liga um perfil a um UID. Se esse UID não
     for o do utilizador que a clínica tem, o SQL corre SEM UM ÚNICO ERRO, cria
     um perfil, e depois NINGUÉM CONSEGUE ENTRAR — «email ou palavra-passe
     inválidos», sem nada que aponte para a causa.

     Isto só se confirma aqui, e é o único sítio onde se confirma. */
  select p.id, p.email into v_admin_uid, v_admin_email
    from public.perfis p where p.perfil = 'administrador' order by p.created_at limit 1;

  if v_admin_uid is null then
    raise warning ' [X] Nao existe nenhum perfil de administrador.';
    raise warning '     O bootstrap nao correu. Ve a PARTE 3 deste ficheiro.';
    v_problemas := v_problemas + 1;
  else
    select exists (select 1 from auth.users u where u.id = v_admin_uid) into v_existe;

    if v_existe then
      raise notice ' [ok] O administrador % existe em auth.users.', v_admin_email;
      raise notice '       UID: %', v_admin_uid;
    else
      raise warning ' [X] O administrador % NAO EXISTE em auth.users.', v_admin_email;
      raise warning '     UID ligado: %', v_admin_uid;
      raise warning '     NINGUEM CONSEGUE ENTRAR assim. O SQL nao tem como saber o UID';
      raise warning '     certo — isso e do Supabase. Faz isto:';
      raise warning '       1. Authentication > Users — confirma o UID do administrador.';
      raise warning '       2. Se for diferente, corre outra vez a PARTE 3 com o UID certo.';
      raise warning '       3. Se for igual, cria o utilizador com «Auto Confirm User».';
      v_problemas := v_problemas + 1;
    end if;
  end if;

  /* -------------------------------------------------------------------------
     2. OS PERFIS ATIVOS
     ------------------------------------------------------------------------- */
  select count(*) into v_ativos from public.perfis where ativo;
  if v_ativos = 0 then
    raise warning ' [X] Nenhum perfil ativo. Ninguem consegue entrar.';
    v_problemas := v_problemas + 1;
  else
    raise notice ' [ok] % perfil(es) ativo(s).', v_ativos;
  end if;

  /* -------------------------------------------------------------------------
     3. AS TABELAS DE CLIENTE SEM RLS
     -------------------------------------------------------------------------
     O defeito mais grave possível neste programa: uma tabela com clinica_id e
     sem RLS deixa um cliente ver os doentes de OUTRO cliente. */
  select coalesce(array_agg(c.relname), '{}') into v_sem_rls
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
     and a.attname = 'clinica_id' and a.attnum > 0 and not a.attisdropped;

  if array_length(v_sem_rls, 1) > 0 then
    raise warning ' [X] TABELAS DE CLIENTE SEM RLS: %', array_to_string(v_sem_rls, ', ');
    raise warning '     Uma tabela destas deixa um cliente ver os dados de outro.';
    raise warning '     NAO PONHAS ISTO EM PRODUCAO assim.';
    v_problemas := v_problemas + 1;
  else
    raise notice ' [ok] RLS ativo em todas as tabelas de cliente.';
  end if;

  /* -------------------------------------------------------------------------
     4. AS VISTAS QUE CONTORNAM O RLS
     -------------------------------------------------------------------------
     Por omissão, uma vista corre com os privilégios do DONO e passa por cima
     das políticas das tabelas de baixo. É uma porta lateral: todas as vistas
     deste projeto têm security_invoker. */
  select coalesce(array_agg(c.relname), '{}') into v_vistas_maus
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'
     and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker%';

  if array_length(v_vistas_maus, 1) > 0 then
    raise warning ' [X] VISTAS QUE CONTORNAM O RLS: %', array_to_string(v_vistas_maus, ', ');
    v_problemas := v_problemas + 1;
  else
    raise notice ' [ok] Todas as vistas respeitam o RLS.';
  end if;

  /* -------------------------------------------------------------------------
     5. O QUE ESTA INSTALAÇÃO TEM, EM NOMES E NÃO EM NÚMEROS
     ------------------------------------------------------------------------- */
  select exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname = 'utente_alergias') into v_alergias;
  select exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname = 'utente_medicacao') into v_medicacao;
  select exists (select 1 from public.ecras where codigo = 'codigo_consentimento') into v_ecra_codigo;

  raise notice '';
  raise notice ' Modulos desta instalacao:';
  raise notice '   % alergias estruturadas', case when v_alergias then '[ok]' else '[--]' end;
  raise notice '   % medicacao ativa e historica', case when v_medicacao then '[ok]' else '[--]' end;
  raise notice '   % codigo do consentimento, pedido pelo profissional',
    case when v_ecra_codigo then '[ok]' else '[--]' end;

  /* -------------------------------------------------------------------------
     O VEREDICTO
     ------------------------------------------------------------------------- */
  raise notice '';
  if v_problemas = 0 then
    raise notice ' =============================================';
    raise notice '  INSTALACAO VERIFICADA — sem problemas';
    raise notice ' =============================================';
    raise notice ' Proximo passo: abrir a aplicacao e entrar com %.',
      coalesce(v_admin_email, '(sem administrador)');
  else
    raise warning ' =============================================';
    raise warning '  % PROBLEMA(S) A RESOLVER ANTES DE USAR', v_problemas;
    raise warning ' =============================================';
    raise warning ' Le os avisos acima: cada um diz o que fazer.';
  end if;
  raise notice '';
end $$;
