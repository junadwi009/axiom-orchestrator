import os
from agents.database_handler import DatabaseHandler

class KnowledgeManager:
    def __init__(self):
        self.db = DatabaseHandler()
        # Langsung ke folder knowledge
        self.knowledge_path = "knowledge/"

    def sync_protocols_to_db(self):
        """Membaca file .md langsung dari folder knowledge/"""
        if not os.path.exists(self.knowledge_path):
            print(f"⚠️ [KNOWLEDGE] Folder {self.knowledge_path} tidak ditemukan!")
            return

        for filename in os.listdir(self.knowledge_path):
            if filename.endswith(".md"):
                entity_name = filename.replace(".md", "").upper()
                file_full_path = os.path.join(self.knowledge_path, filename)
                
                with open(file_full_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # Simpan ke SQL
                self.db.save_knowledge(
                    source=entity_name,
                    pattern_name="CORE_PROTOCOL",
                    content=content, # Isi teks .md
                    summary=f"Protokol dasar agen {entity_name}",
                    file_path=file_full_path
                )
        print("📚 [KNOWLEDGE] Sinkronisasi folder knowledge/ ke SQL selesai.")

if __name__ == "__main__":
    manager = KnowledgeManager()
    manager.sync_protocols_to_db()
