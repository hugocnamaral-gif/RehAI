-- ============================================================================
-- clinia.ai · migração 0045 — O ECRÃ DO CONSENTIMENTO EM PAPEL CHEGA AO MENU
-- ============================================================================
--
-- O PROBLEMA (visto no TESTE, 2026-10-20)
--   O ecrã `consentimento_papel` existe na aplicação (ecras/consentimento-papel.js)
--   e está na lista do menu (app.js), mas NUNCA foi registado no catálogo
--   `public.ecras`. O menu só mostra o que o servidor atribui ao perfil, por isso
--   o ecrã não aparecia a ninguém. O `codigo_consentimento` teve o seu registo na
--   0024; o papel ficou esquecido.
--
-- PERFIS
--   Os clínicos, o administrador e a RECEÇÃO: a folha assinada chega ao balcão,
--   e a política de escrita em `consentimentos` (0010) já aceita
--   `e_rececao_ou_melhor()`.
--
-- ÁREA «administrativa», e não «clinica»: na área clínica a receção recebe o
--   ecrã só em leitura (regra do seed 0006), e então não conseguia registar a
--   folha — que é precisamente para o que o ecrã existe.
--
-- Idempotente: corre duas vezes sem efeito na segunda.
-- ============================================================================

insert into public.ecras (codigo, nome, grupo, ordem, area, visivel_em, obrigatorio)
values ('consentimento_papel', 'Consentimento em papel', 'Processo clínico', 66, 'administrativa',
        '{administrador,fisiatra,fisioterapeuta,osteopata,terapeuta_ocupacional,terapeuta_da_fala,psicologo,enfermeiro,rececao}',
        false)
on conflict (codigo) do update
  set visivel_em = excluded.visivel_em,
      nome       = excluded.nome,
      grupo      = excluded.grupo,
      area       = excluded.area;

-- Atribuir às clínicas que JÁ existem (as novas recebem-no pelo gatilho de
-- `clinicas`, que lê o catálogo). Sem isto, a linha no catálogo não chega ao
-- menu de ninguém numa base já instalada.
do $papel$
declare
  v_ecra uuid;
begin
  perform set_config('clinia.a_semear_visibilidade', 'sim', true);

  select id into v_ecra from public.ecras where codigo = 'consentimento_papel';

  insert into public.perfil_visibilidade (clinica_id, perfil, ecra_id, visivel, apenas_leitura)
  select c.id, p.perfil::public.perfil_tipo, v_ecra, true, false
    from public.clinicas c
   cross join unnest(array['administrador','fisiatra','fisioterapeuta','osteopata',
                           'terapeuta_ocupacional','terapeuta_da_fala','psicologo',
                           'enfermeiro','rececao']) as p(perfil)
  on conflict (clinica_id, perfil, ecra_id) do nothing;

  perform set_config('clinia.a_semear_visibilidade', 'nao', true);
end $papel$;
