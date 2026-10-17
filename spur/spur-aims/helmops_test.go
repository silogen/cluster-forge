package main

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func TestPullInProgress(t *testing.T) {
	pod := func(reason string) corev1.Pod {
		return corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: "postgres-0", Namespace: "db", UID: "new"},
			Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{{
				State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: reason}},
			}}},
		}
	}
	event := func(uid types.UID, reason, message string) corev1.Event {
		return corev1.Event{
			InvolvedObject: corev1.ObjectReference{Kind: "Pod", UID: uid},
			Reason:         reason,
			Message:        message,
		}
	}
	at := func(e corev1.Event, minute int) corev1.Event {
		e.LastTimestamp = metav1.NewTime(time.Date(2026, 1, 1, 0, minute, 0, 0, time.UTC))
		return e
	}
	pulling := event("new", "Pulling", `Pulling image "postgres:17-alpine"`)
	cases := []struct {
		name   string
		pods   []corev1.Pod
		events []corev1.Event
		want   string
	}{
		{"pull without a result", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{pulling}, "pod db/postgres-0 pulls postgres:17-alpine"},
		{"pull done", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{pulling, event("new", "Pulled", `Successfully pulled image "postgres:17-alpine" in 9m`)}, ""},
		{"pull failed", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{pulling, event("new", "Failed", `Failed to pull image "postgres:17-alpine": not found`)}, ""},
		{"no pull event", []corev1.Pod{pod("ContainerCreating")}, nil, ""},
		{"event of an earlier pod with the same name", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{event("old", "Pulling", `Pulling image "postgres:17-alpine"`)}, ""},
		{"pod not in ContainerCreating", []corev1.Pod{pod("CrashLoopBackOff")},
			[]corev1.Event{pulling}, ""},
		{"second image still pulls", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{
				pulling,
				event("new", "Pulled", `Successfully pulled image "postgres:17-alpine" in 9m`),
				event("new", "Pulling", `Pulling image "busybox:1.36"`),
			}, "pod db/postgres-0 pulls busybox:1.36"},
		{"new pull after an earlier failed pull", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{
				at(pulling, 3),
				at(event("new", "Failed", `Failed to pull image "postgres:17-alpine": timeout`), 1),
			}, "pod db/postgres-0 pulls postgres:17-alpine"},
		{"failed pull after a pull", []corev1.Pod{pod("ContainerCreating")},
			[]corev1.Event{
				at(pulling, 1),
				at(event("new", "Failed", `Failed to pull image "postgres:17-alpine": timeout`), 3),
			}, ""},
	}
	for _, c := range cases {
		if got := pullInProgress(c.pods, c.events); got != c.want {
			t.Errorf("%s: pullInProgress() = %q, want %q", c.name, got, c.want)
		}
	}
}
