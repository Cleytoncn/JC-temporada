# Plano de implantação — JC Temporada

## Escala inicial e destino

- Carga atual: 120 apartamentos.
- Meta: 300 ou mais apartamentos, com paginação, filtros por empreendimento e mapa de ocupação eficiente.
- Projeto de hospedagem **independente** do Sistema Financeiro.
- A demonstração na Vercel, atualmente alimentada por dados locais de teste, **não é sistema de produção**.

## Regras operacionais

1. Todo registro de reserva novo começa **amarelo** (pré-reserva) e com R$ 0 recebido.
2. Primeiro recebimento parcial: cor **azul**, independentemente do percentual (ex.: 30%).
3. Valor recebido igual ao total: cor **verde**.
4. Bloqueio de disponibilidade: **vermelho**.
5. Manutenção: **cinza-escuro**.
6. As cores das reservas vêm do somatório de recebimentos; não são editadas manualmente.
7. Seleção da data 10 à 12 na grade significa **entrada dia 10 e saída dia 12**.
8. A regra de não sobreposição deve valer para reservas, bloqueios e manutenção, inclusive sob concorrência.
9. Importações externas não devem tratar automaticamente dinheiro pago ao canal como dinheiro recebido pela JC.

## Integrações — requisitos e dependências

Canais pretendidos: Airbnb, Booking.com, Decolar e Expedia.

- A sincronização bidirecional (reservas, cancelamentos, disponibilidade, preços) depende dos programas/API e acessos autorizados por cada canal.
- Não criar promessas de integração completa sem homologação.
- Planejar sincronização idempotente por identificador externo, controle de erros, fila de retentativas, auditoria e reconciliação periódica.
- Definir previamente qual sistema é fonte de verdade para cada campo durante a migração.
- Executar homologação e operação paralela antes de desligar a Stays.

## Preparação da infraestrutura

- [x] Revisar projetos conectados: existe somente um Supabase com nome Sistema Financeiro.
- [x] Manter o banco do Sistema Financeiro intocado.
- [x] Criar arquivo de migração SQL no repositório JC-temporada; ainda **não aplicado**.
- [ ] Confirmar organização e custos e criar novo Supabase dedicado.
- [ ] Revisar políticas RLS, fluxos de autenticação, usuários, permissões e 2FA.
- [ ] Testar migração SQL em banco isolado e corrigir revisões de segurança.
- [ ] Criar backend transacional, log de auditoria, anexos e testes automatizados.
- [ ] Migrar imóveis, hóspedes e reservas via exportação autorizada, preservando referências.
- [ ] Iniciar testes com 120 imóveis e carga sintética para 300+.
- [ ] Integrar cada canal por etapas e homologar; testar cancelamentos e conflitos.
- [ ] Ativar gradualmente com plano de reversão; desligar a Stays só após operação validada.

## Testes obrigatórios

- Duas pessoas tentando reservar o mesmo apartamento/dias simultaneamente: apenas uma deve conseguir.
- Entrada dia 10 e saída dia 12: bloqueia noites 10 e 11, mas libera check-in dia 12.
- Reserva recém-criada sem pagamento: status `pre_reservation`.
- 30% registrado: status `partially_paid`.
- 100% registrado: status `paid_in_full`.
- Pagamento acima do saldo deve falhar no banco.
- Funcionário de organização A não pode ler nem alterar hóspedes/reservas da organização B.
- Reserva cancelada deve deixar datas disponíveis, sem apagar histórico de auditoria.
- Pagamentos de canais externos precisam de reconciliação, sem marcar quitado por suposição.
- Cenários móveis: selecionar intervalo com dedo, abrir opção pré-reserva/bloqueio/manutenção, editar e salvar.
- Testar recuperação de senha, sessão expirada e autenticação forte.
- Verificar backups e capacidade de restauração.

## Observações de segurança

O esquema SQL em `supabase/migrations/20261012_001_initial.sql` é uma base de desenvolvimento, não um produto homologado. Exige auditoria de permissões e integridade antes do uso real. Nunca adicionar chaves privadas ou dados reais ao repositório. O GitHub da JC-temporada está atualmente público; avaliar torná-lo privado antes de avançar com código da empresa.
