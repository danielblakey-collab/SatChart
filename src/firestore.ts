import admin from "firebase-admin";

export function initFirestore() {
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
  return admin.firestore();
}
