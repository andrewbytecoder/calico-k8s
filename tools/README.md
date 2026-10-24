chmod +x load-images-to-kind.sh

# 单个 tar
./load-images-to-kind.sh my-cluster ./my-app-v1.tar

# 多个 tar
./load-images-to-kind.sh my-cluster ./my-app-v1.tar ./nginx-1.25.tar ./busybox.tar

# 通配符（shell 展开）
./load-images-to-kind.sh my-cluster ./images/*.tar
