<script>
import { useAlert } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: { NextButton },
  props: {
    absence: { type: Object, default: null },
    agents: { type: Array, default: () => [] },
  },
  emits: ['close'],
  data() {
    return {
      form: {
        user_id: this.absence?.user_id || null,
        coverage_user_id: this.absence?.coverage_user_id || null,
        start_at: this.absence?.start_at?.slice(0, 16) || '',
        end_at: this.absence?.end_at?.slice(0, 16) || '',
        reason: this.absence?.reason || '',
        status: this.absence?.status || 'scheduled',
      },
      saving: false,
    };
  },
  computed: {
    isEdit() {
      return !!this.absence?.id;
    },
    statuses() {
      return ['scheduled', 'active', 'ended', 'cancelled'];
    },
    coverageOptions() {
      return this.agents.filter(a => a.id !== this.form.user_id);
    },
  },
  methods: {
    async submit() {
      this.saving = true;
      try {
        const payload = {
          ...this.form,
          start_at: new Date(this.form.start_at).toISOString(),
          end_at: new Date(this.form.end_at).toISOString(),
        };
        if (this.isEdit) {
          await this.$store.dispatch('adakiAbsences/update', { id: this.absence.id, ...payload });
          useAlert('Ausencia actualizada');
        } else {
          await this.$store.dispatch('adakiAbsences/create', payload);
          useAlert('Ausencia creada');
        }
        this.$emit('close');
      } catch (e) {
        useAlert(e.message || 'Error al guardar');
      } finally {
        this.saving = false;
      }
    },
  },
};
</script>

<template>
  <div class="p-6 w-[480px]">
    <h2 class="text-heading-2 mb-4">{{ isEdit ? 'Editar ausencia' : 'Nueva ausencia' }}</h2>
    <form class="flex flex-col gap-4" @submit.prevent="submit">
      <label class="flex flex-col gap-1">
        <span class="text-body-main">Agente ausente</span>
        <select v-model="form.user_id" required :disabled="isEdit" class="form-input">
          <option :value="null" disabled>Selecciona agente</option>
          <option v-for="a in agents" :key="a.id" :value="a.id">{{ a.name }}</option>
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">Cobertura (opcional)</span>
        <select v-model="form.coverage_user_id" class="form-input">
          <option :value="null">Sin cobertura asignada</option>
          <option v-for="a in coverageOptions" :key="a.id" :value="a.id">{{ a.name }}</option>
        </select>
      </label>
      <div class="grid grid-cols-2 gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-body-main">Inicio</span>
          <input v-model="form.start_at" type="datetime-local" required class="form-input" />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-body-main">Fin</span>
          <input v-model="form.end_at" type="datetime-local" required class="form-input" />
        </label>
      </div>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">Estado</span>
        <select v-model="form.status" class="form-input">
          <option v-for="s in statuses" :key="s" :value="s">{{ s }}</option>
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">Motivo</span>
        <input v-model="form.reason" type="text" class="form-input" placeholder="Vacaciones, baja, etc." />
      </label>
      <div class="flex justify-end gap-2 mt-2">
        <NextButton type="button" label="Cancelar" slate sm @click="$emit('close')" />
        <NextButton type="submit" :label="isEdit ? 'Guardar' : 'Crear'" sm :is-loading="saving" />
      </div>
    </form>
  </div>
</template>
