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
          await this.$store.dispatch('adakiAbsences/update', {
            id: this.absence.id,
            ...payload,
          });
          useAlert(this.$t('ADAKI.ABSENCES.ALERTS.UPDATED'));
        } else {
          await this.$store.dispatch('adakiAbsences/create', payload);
          useAlert(this.$t('ADAKI.ABSENCES.ALERTS.CREATED'));
        }
        this.$emit('close');
      } catch (e) {
        useAlert(e.message || this.$t('ADAKI.ABSENCES.ALERTS.ERROR'));
      } finally {
        this.saving = false;
      }
    },
  },
};
</script>

<template>
  <div class="p-6 w-[480px]">
    <h2 class="text-heading-2 mb-4">
      {{
        isEdit
          ? $t('ADAKI.ABSENCES.FORM.TITLE_EDIT')
          : $t('ADAKI.ABSENCES.FORM.TITLE_NEW')
      }}
    </h2>
    <form class="flex flex-col gap-4" @submit.prevent="submit">
      <label class="flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.ABSENCES.FORM.USER_LABEL')
        }}</span>
        <select
          v-model="form.user_id"
          required
          :disabled="isEdit"
          class="form-input"
        >
          <option :value="null" disabled>
            {{ $t('ADAKI.ABSENCES.FORM.USER_PLACEHOLDER') }}
          </option>
          <option v-for="a in agents" :key="a.id" :value="a.id">
            {{ a.name }}
          </option>
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.ABSENCES.FORM.COVERAGE_LABEL')
        }}</span>
        <select v-model="form.coverage_user_id" class="form-input">
          <option :value="null">
            {{ $t('ADAKI.ABSENCES.FORM.COVERAGE_NONE') }}
          </option>
          <option v-for="a in coverageOptions" :key="a.id" :value="a.id">
            {{ a.name }}
          </option>
        </select>
      </label>
      <div class="grid grid-cols-2 gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.ABSENCES.FORM.START_LABEL')
          }}</span>
          <input
            v-model="form.start_at"
            type="datetime-local"
            required
            class="form-input"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.ABSENCES.FORM.END_LABEL')
          }}</span>
          <input
            v-model="form.end_at"
            type="datetime-local"
            required
            class="form-input"
          />
        </label>
      </div>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.ABSENCES.FORM.STATUS_LABEL')
        }}</span>
        <select v-model="form.status" class="form-input">
          <option v-for="s in statuses" :key="s" :value="s">{{ s }}</option>
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.ABSENCES.FORM.REASON_LABEL')
        }}</span>
        <input
          v-model="form.reason"
          type="text"
          class="form-input"
          :placeholder="$t('ADAKI.ABSENCES.FORM.REASON_PLACEHOLDER')"
        />
      </label>
      <div class="flex justify-end gap-2 mt-2">
        <NextButton
          type="button"
          :label="$t('ADAKI.ABSENCES.FORM.CANCEL')"
          slate
          sm
          @click="$emit('close')"
        />
        <NextButton
          type="submit"
          :label="
            isEdit
              ? $t('ADAKI.ABSENCES.FORM.SAVE')
              : $t('ADAKI.ABSENCES.FORM.CREATE')
          "
          sm
          :is-loading="saving"
        />
      </div>
    </form>
  </div>
</template>
